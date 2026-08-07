defmodule Revela.Capture.CameraServerTest do
  use Revela.DataCase, async: false

  alias Revela.Capture
  alias Revela.Capture.CameraServer

  test "restaura editorial ativo do banco no boot" do
    editorials_dir = temporary_editorials_dir()
    folder = Path.join(editorials_dir, "2026-08-06 Casamento 120000-1")
    File.mkdir_p!(folder)

    {:ok, editorial} = Capture.start_editorial("Casamento", folder)
    {:ok, photo} = Capture.create_photo(%{web_path: "/uploads/restore.jpg"})

    server =
      start_supervised!({
        CameraServer,
        name: nil,
        editorials_dir: editorials_dir,
        presence_detector: fn -> false end,
        presence_poll_ms: 60_000
      })

    wait_for_presence_check(server)

    assert CameraServer.status(server).editorial == "Casamento"
    assert :sys.get_state(server).captures_dir == folder
    assert Capture.current_editorial_id() == editorial.id
    assert Capture.list_photos() == [photo]
  end

  test "sem editorial ativo inicia no limbo" do
    editorials_dir = temporary_editorials_dir()

    server =
      start_supervised!({
        CameraServer,
        name: nil,
        editorials_dir: editorials_dir,
        presence_detector: fn -> false end,
        presence_poll_ms: 60_000
      })

    wait_for_presence_check(server)

    assert CameraServer.status(server).editorial == nil
    assert :sys.get_state(server).captures_dir == Path.join(editorials_dir, "_sem-editorial")
  end

  test "nao arma a captura quando nenhuma camera foi detectada" do
    detector_state = start_supervised!({Agent, fn -> false end})
    Capture.subscribe_status()

    server =
      start_supervised!({
        CameraServer,
        name: nil,
        editorials_dir: temporary_editorials_dir(),
        presence_detector: fn -> Agent.get(detector_state, & &1) end,
        presence_poll_ms: 60_000
      })

    wait_for_presence_check(server)

    assert %{camera_present: false, editorial: nil, message: nil, status: :idle} =
             CameraServer.start_capture(server)

    Agent.update(detector_state, fn _present? -> true end)
    send(server, :poll_presence)

    assert_receive {:capture_status, %{camera_present: true, status: :idle}}
    assert CameraServer.status(server).status == :idle
  end

  test "expoe espaco livre e a estimativa de fotos restantes no status" do
    server =
      start_supervised!({
        CameraServer,
        name: nil,
        editorials_dir: temporary_editorials_dir(),
        presence_poll_ms: 60_000,
        disk_poll_ms: 60_000,
        disk_checker: fn _dir -> 42_000_000_000 end
      })

    status = CameraServer.status(server)

    assert status.free_disk_bytes == 42_000_000_000
    assert status.disk_awareness == :available
    assert is_integer(status.estimated_shots_left)
    assert status.estimated_shots_left > 0
  end

  test "marca disk_awareness como unavailable quando o checker falha" do
    server =
      start_supervised!({
        CameraServer,
        name: nil,
        editorials_dir: temporary_editorials_dir(),
        presence_poll_ms: 60_000,
        disk_poll_ms: 60_000,
        disk_checker: fn _dir -> :unavailable end
      })

    status = CameraServer.status(server)

    assert status.disk_awareness == :unavailable
    assert status.free_disk_bytes == nil
    assert status.estimated_shots_left == nil
  end

  test "estima bytes por disparo (RAW+JPEG do mesmo stem), nao por arquivo" do
    editorials_dir = temporary_editorials_dir()
    captures_dir = Path.join(editorials_dir, "_sem-editorial")
    File.mkdir_p!(captures_dir)
    File.write!(Path.join(captures_dir, "shot1.jpg"), :binary.copy(<<0>>, 10))
    File.write!(Path.join(captures_dir, "shot1.cr2"), :binary.copy(<<0>>, 20))

    server =
      start_supervised!({
        CameraServer,
        name: nil,
        editorials_dir: editorials_dir,
        presence_poll_ms: 60_000,
        disk_poll_ms: 60_000,
        disk_checker: fn _dir -> 90 end
      })

    # media por disparo = 30 bytes; 90 livres => ~3 fotos (nao ~6 se fosse por arquivo)
    assert CameraServer.status(server).estimated_shots_left == 3
  end

  test "para a captura sozinha quando o espaco livre cai abaixo do minimo, sem transferencia em curso" do
    detector_state =
      start_supervised!(Supervisor.child_spec({Agent, fn -> true end}, id: :detector_state))

    Capture.subscribe_status()

    disk_state =
      start_supervised!(Supervisor.child_spec({Agent, fn -> 10_000_000_000 end}, id: :disk_state))

    server =
      start_supervised!({
        CameraServer,
        name: nil,
        editorials_dir: temporary_editorials_dir(),
        presence_detector: fn -> Agent.get(detector_state, & &1) end,
        presence_poll_ms: 60_000,
        disk_poll_ms: 60_000,
        transfer_quiet_ms: 50,
        min_free_disk_bytes: 5_000_000_000,
        disk_checker: fn _dir -> Agent.get(disk_state, & &1) end
      })

    wait_for_presence_check(server)

    # forca :running sem depender de um binario gphoto2 real: o que se testa
    # aqui e a logica de parada por disco, nao o spawn do processo externo.
    :sys.replace_state(server, &%{&1 | status: :running, desired: true})

    # ainda com espaco de sobra: o poll nao deve parar a captura
    send(server, :poll_disk)
    refute_receive {:capture_status, %{status: :disk_full}}, 100
    assert CameraServer.status(server).status == :running

    # simula uma transferencia em curso (arquivo ainda "assentando"): mesmo
    # com o disco baixo, a parada NAO pode acontecer nesse instante
    :sys.replace_state(server, &%{&1 | pending: %{"/tmp/foo.jpg" => make_ref()}})
    Agent.update(disk_state, fn _free -> 1_000_000_000 end)
    send(server, :poll_disk)
    refute_receive {:capture_status, %{status: :disk_full}}, 100
    assert CameraServer.status(server).status == :running

    # RAW em pending tambem bloqueia (mesmo sem JPEG)
    :sys.replace_state(server, &%{&1 | pending: %{"/tmp/foo.cr2" => make_ref()}})
    send(server, :poll_disk)
    refute_receive {:capture_status, %{status: :disk_full}}, 100
    assert CameraServer.status(server).status == :running

    # transferencia concluida (pending vazio de novo): agora sim, entre
    # disparos, e seguro parar
    :sys.replace_state(server, &%{&1 | pending: %{}, last_transfer_at: nil})
    send(server, :poll_disk)

    assert_receive {:capture_status, %{status: :disk_full, message: message}}
    assert message =~ "Espaço em disco"
    assert message =~ "rearma automaticamente"

    final = CameraServer.status(server)
    assert final.status == :disk_full
    assert :sys.get_state(server).port == nil
  end

  test "nao para por disco enquanto a janela quiet de transferencia ainda esta aberta" do
    Capture.subscribe_status()

    server =
      start_supervised!({
        CameraServer,
        name: nil,
        editorials_dir: temporary_editorials_dir(),
        presence_poll_ms: 60_000,
        disk_poll_ms: 60_000,
        transfer_quiet_ms: 5_000,
        min_free_disk_bytes: 5_000_000_000,
        disk_checker: fn _dir -> 1_000_000_000 end
      })

    now = System.monotonic_time(:millisecond)

    :sys.replace_state(
      server,
      &%{&1 | status: :running, desired: true, pending: %{}, last_transfer_at: now}
    )

    send(server, :poll_disk)
    refute_receive {:capture_status, %{status: :disk_full}}, 100
    assert CameraServer.status(server).status == :running
    assert is_reference(:sys.get_state(server).quiet_disk_check_ref)

    :sys.replace_state(server, &%{&1 | last_transfer_at: now - 6_000, quiet_disk_check_ref: nil})
    send(server, :poll_disk)

    assert_receive {:capture_status, %{status: :disk_full}}
  end

  test "stdout reagenda quiet disk check quando pending esta vazio" do
    server =
      start_supervised!({
        CameraServer,
        name: nil,
        editorials_dir: temporary_editorials_dir(),
        presence_poll_ms: 60_000,
        disk_poll_ms: 60_000,
        transfer_quiet_ms: 5_000,
        min_free_disk_bytes: 5_000_000_000,
        disk_checker: fn _dir -> 1_000_000_000 end
      })

    fake_port = make_ref()
    old_ref = make_ref()

    :sys.replace_state(
      server,
      &%{
        &1
        | status: :running,
          desired: true,
          port: fake_port,
          pending: %{},
          quiet_disk_check_ref: old_ref
      }
    )

    send(server, {fake_port, {:data, "Saving file as /tmp/foo.jpg"}})
    state = :sys.get_state(server)

    assert is_reference(state.quiet_disk_check_ref)
    assert state.quiet_disk_check_ref != old_ref
    assert is_integer(state.last_transfer_at)
  end

  test "usa fallback de media quando arquivos do editorial tem tamanho zero" do
    editorials_dir = temporary_editorials_dir()
    captures_dir = Path.join(editorials_dir, "_sem-editorial")
    File.mkdir_p!(captures_dir)
    File.write!(Path.join(captures_dir, "empty.jpg"), "")

    fallback = 30 * 1024 * 1024
    free_bytes = fallback * 4

    server =
      start_supervised!({
        CameraServer,
        name: nil,
        editorials_dir: editorials_dir,
        presence_poll_ms: 60_000,
        disk_poll_ms: 60_000,
        disk_checker: fn _dir -> free_bytes end
      })

    assert CameraServer.status(server).estimated_shots_left == 4
  end

  test "estima fotos com media fracionaria abaixo de 1 byte sem crashar" do
    editorials_dir = temporary_editorials_dir()
    captures_dir = Path.join(editorials_dir, "_sem-editorial")
    File.mkdir_p!(captures_dir)
    File.write!(Path.join(captures_dir, "tiny.jpg"), <<0>>)
    File.write!(Path.join(captures_dir, "empty1.jpg"), "")
    File.write!(Path.join(captures_dir, "empty2.jpg"), "")

    server =
      start_supervised!({
        CameraServer,
        name: nil,
        editorials_dir: editorials_dir,
        presence_poll_ms: 60_000,
        disk_poll_ms: 60_000,
        disk_checker: fn _dir -> 10 end
      })

    assert CameraServer.status(server).estimated_shots_left == 10
  end

  test "settle refresca last_transfer_at antes da checagem de disco" do
    editorials_dir = temporary_editorials_dir()
    captures_dir = Path.join(editorials_dir, "_sem-editorial")
    File.mkdir_p!(captures_dir)
    raw_path = Path.join(captures_dir, "shot.cr2")
    File.write!(raw_path, <<0, 1, 2>>)

    server =
      start_supervised!({
        CameraServer,
        name: nil,
        editorials_dir: editorials_dir,
        presence_poll_ms: 60_000,
        disk_poll_ms: 60_000,
        transfer_quiet_ms: 5_000,
        min_free_disk_bytes: 5_000_000_000,
        disk_checker: fn _dir -> 1_000_000_000 end
      })

    stale_at = System.monotonic_time(:millisecond) - 10_000

    :sys.replace_state(
      server,
      &%{
        &1
        | status: :running,
          desired: true,
          pending: %{raw_path => make_ref()},
          last_transfer_at: stale_at
      }
    )

    send(server, {:settle, raw_path})
    state = :sys.get_state(server)

    assert state.last_transfer_at > stale_at
    assert state.status == :running
    assert map_size(state.pending) == 0
  end

  test "mensagem de disco baixo inclui cabem ~0 fotos" do
    Capture.subscribe_status()

    server =
      start_supervised!({
        CameraServer,
        name: nil,
        editorials_dir: temporary_editorials_dir(),
        presence_poll_ms: 60_000,
        disk_poll_ms: 60_000,
        transfer_quiet_ms: 50,
        min_free_disk_bytes: 5_000_000_000,
        disk_checker: fn _dir -> 100 end
      })

    :sys.replace_state(
      server,
      &%{&1 | status: :running, desired: true, pending: %{}, last_transfer_at: nil}
    )

    send(server, :poll_disk)

    assert_receive {:capture_status, %{status: :disk_full, message: message}}
    assert message =~ "cabem ~0 fotos"
    assert CameraServer.status(server).estimated_shots_left == 0
  end

  test "recusa rearmar a captura enquanto o disco ainda esta abaixo do minimo" do
    detector_state =
      start_supervised!(Supervisor.child_spec({Agent, fn -> true end}, id: :rearm_detector))

    Capture.subscribe_status()

    server =
      start_supervised!({
        CameraServer,
        name: nil,
        editorials_dir: temporary_editorials_dir(),
        presence_detector: fn -> Agent.get(detector_state, & &1) end,
        presence_poll_ms: 60_000,
        disk_poll_ms: 60_000,
        min_free_disk_bytes: 5_000_000_000,
        disk_checker: fn _dir -> 1_000_000_000 end
      })

    wait_for_presence_check(server)

    status = CameraServer.start_capture(server)

    assert status.status == :disk_full
    assert status.message =~ "Espaço em disco"
    assert :sys.get_state(server).port == nil
    assert :sys.get_state(server).desired == false
  end

  test "trocar de editorial cancela settles pendentes da pasta anterior" do
    editorials_dir = temporary_editorials_dir()

    server =
      start_supervised!({
        CameraServer,
        name: nil,
        editorials_dir: editorials_dir,
        presence_detector: fn -> false end,
        presence_poll_ms: 60_000
      })

    wait_for_presence_check(server)

    old_dir = Path.join(editorials_dir, "_sem-editorial")
    old_path = Path.join(old_dir, "pending.jpg")
    File.write!(old_path, "not-a-real-jpeg")

    ref = Process.send_after(server, {:settle, old_path}, 60_000)

    :sys.replace_state(server, fn state ->
      %{state | pending: Map.put(state.pending, old_path, ref)}
    end)

    assert {:ok, %{folder: folder}} = GenServer.call(server, {:set_editorial, "Casamento", nil})
    assert File.dir?(folder)
    assert :sys.get_state(server).pending == %{}
    assert Process.read_timer(ref) == false

    send(server, {:settle, old_path})
    _ = :sys.get_state(server)

    assert :sys.get_state(server).pending == %{}
    assert :sys.get_state(server).processed == MapSet.new()
  end

  test "reservar pasta do editorial desliga captura e cancela settles antes do start_editorial" do
    editorials_dir = temporary_editorials_dir()

    server =
      start_supervised!({
        CameraServer,
        name: nil,
        editorials_dir: editorials_dir,
        presence_detector: fn -> false end,
        presence_poll_ms: 60_000
      })

    wait_for_presence_check(server)

    old_dir = Path.join(editorials_dir, "_sem-editorial")
    old_path = Path.join(old_dir, "pending.jpg")
    File.write!(old_path, "not-a-real-jpeg")

    ref = Process.send_after(server, {:settle, old_path}, 60_000)

    :sys.replace_state(server, fn state ->
      %{state | pending: Map.put(state.pending, old_path, ref), desired: true}
    end)

    assert {:ok, %{folder: folder}} =
             GenServer.call(server, {:reserve_editorial_folder, "Casamento"})

    assert File.dir?(folder)
    state = :sys.get_state(server)
    assert state.pending == %{}
    assert state.desired == false
    assert state.captures_dir == old_dir
    assert state.reserved_folder == folder
    assert Process.read_timer(ref) == false

    send(server, {:settle, old_path})
    _ = :sys.get_state(server)

    assert :sys.get_state(server).processed == MapSet.new()
  end

  test "set_editorial reusa a pasta reservada e nao colide com mesmo nome" do
    editorials_dir = temporary_editorials_dir()

    server =
      start_supervised!({
        CameraServer,
        name: nil,
        editorials_dir: editorials_dir,
        presence_detector: fn -> false end,
        presence_poll_ms: 60_000
      })

    wait_for_presence_check(server)

    assert {:ok, %{folder: folder}} =
             GenServer.call(server, {:reserve_editorial_folder, "Casamento"})

    assert {:ok, %{folder: ^folder}} =
             GenServer.call(server, {:set_editorial, "Casamento", folder})

    assert :sys.get_state(server).captures_dir == folder
    assert :sys.get_state(server).reserved_folder == nil

    assert {:ok, %{folder: folder2}} =
             GenServer.call(server, {:reserve_editorial_folder, "Casamento"})

    refute folder == folder2
    assert File.dir?(folder)
    assert File.dir?(folder2)
  end

  test "settle fora da captures_dir atual e ignorado" do
    editorials_dir = temporary_editorials_dir()

    server =
      start_supervised!({
        CameraServer,
        name: nil,
        editorials_dir: editorials_dir,
        presence_detector: fn -> false end,
        presence_poll_ms: 60_000
      })

    wait_for_presence_check(server)

    assert {:ok, _} = GenServer.call(server, {:set_editorial, "Novo", nil})

    foreign =
      Path.join(System.tmp_dir!(), "revela-foreign-#{System.unique_integer([:positive])}.jpg")

    File.write!(foreign, "x")
    on_exit(fn -> File.rm(foreign) end)

    ref = Process.send_after(server, {:settle, foreign}, 60_000)

    :sys.replace_state(server, fn state ->
      %{state | pending: Map.put(state.pending, foreign, ref)}
    end)

    send(server, {:settle, foreign})
    _ = :sys.get_state(server)

    assert :sys.get_state(server).processed == MapSet.new()
    refute MapSet.member?(:sys.get_state(server).processed, foreign)
  end

  test "auto-arma apos debounce com editorial ativo, camera e disco OK" do
    Capture.subscribe_status()
    detector_state = start_supervised!({Agent, fn -> false end})

    server =
      start_supervised!({
        CameraServer,
        name: nil,
        editorials_dir: temporary_editorials_dir(),
        presence_detector: fn -> Agent.get(detector_state, & &1) end,
        presence_poll_ms: 60_000,
        presence_debounce_ms: 30,
        disk_poll_ms: 60_000,
        disk_checker: fn _dir -> 10_000_000_000 end,
        tether_spawner: fn _state -> {:ok, nil, nil} end
      })

    wait_for_presence_check(server)

    assert {:ok, _} = GenServer.call(server, {:set_editorial, "Casamento", nil})
    assert CameraServer.status(server).status == :idle
    refute CameraServer.status(server).auto_arm_pending

    Agent.update(detector_state, fn _ -> true end)
    send(server, :poll_presence)
    wait_for_presence_check(server)

    assert CameraServer.status(server).auto_arm_pending
    assert_receive {:capture_status, %{auto_arm_pending: true, camera_present: true}}

    assert_receive {:capture_status, %{status: :running, armed_automatically: true}}, 500
    assert CameraServer.status(server).status == :running
    assert :sys.get_state(server).desired == true
    assert :sys.get_state(server).operator_stopped == false
  end

  test "nao auto-arma no limbo sem editorial ativo" do
    Capture.subscribe_status()
    detector_state = start_supervised!({Agent, fn -> true end})

    server =
      start_supervised!({
        CameraServer,
        name: nil,
        editorials_dir: temporary_editorials_dir(),
        presence_detector: fn -> Agent.get(detector_state, & &1) end,
        presence_poll_ms: 60_000,
        presence_debounce_ms: 20,
        disk_poll_ms: 60_000,
        disk_checker: fn _dir -> 10_000_000_000 end,
        tether_spawner: fn _state -> {:ok, nil, nil} end
      })

    wait_for_presence_check(server)

    assert CameraServer.status(server).editorial == nil
    assert CameraServer.status(server).camera_present
    refute CameraServer.status(server).auto_arm_pending
    refute_receive {:capture_status, %{status: :running}}, 80
    assert CameraServer.status(server).status == :idle
    assert :sys.get_state(server).desired == false
  end

  test "nao auto-arma quando disk_awareness e unavailable" do
    Capture.subscribe_status()
    detector_state = start_supervised!({Agent, fn -> true end})

    server =
      start_supervised!({
        CameraServer,
        name: nil,
        editorials_dir: temporary_editorials_dir(),
        presence_detector: fn -> Agent.get(detector_state, & &1) end,
        presence_poll_ms: 60_000,
        presence_debounce_ms: 20,
        disk_poll_ms: 60_000,
        disk_checker: fn _dir -> :unavailable end,
        tether_spawner: fn _state -> {:ok, nil, nil} end
      })

    wait_for_presence_check(server)
    assert {:ok, _} = GenServer.call(server, {:set_editorial, "Casamento", nil})

    send(server, :poll_presence)
    wait_for_presence_check(server)

    assert CameraServer.status(server).disk_awareness == :unavailable
    assert CameraServer.status(server).camera_present
    refute CameraServer.status(server).auto_arm_pending
    refute_receive {:capture_status, %{status: :running}}, 80
    assert :sys.get_state(server).desired == false
  end

  test "nao auto-arma quando o disco esta abaixo do minimo" do
    Capture.subscribe_status()
    detector_state = start_supervised!({Agent, fn -> true end})

    server =
      start_supervised!({
        CameraServer,
        name: nil,
        editorials_dir: temporary_editorials_dir(),
        presence_detector: fn -> Agent.get(detector_state, & &1) end,
        presence_poll_ms: 60_000,
        presence_debounce_ms: 20,
        disk_poll_ms: 60_000,
        min_free_disk_bytes: 5_000_000_000,
        disk_checker: fn _dir -> 1_000_000_000 end,
        tether_spawner: fn _state -> {:ok, nil, nil} end
      })

    wait_for_presence_check(server)
    assert {:ok, _} = GenServer.call(server, {:set_editorial, "Casamento", nil})

    send(server, :poll_presence)
    wait_for_presence_check(server)

    refute CameraServer.status(server).auto_arm_pending
    refute_receive {:capture_status, %{status: :running}}, 80
    assert :sys.get_state(server).desired == false
  end

  test "stop explicito gruda: nao rearma enquanto a camera continua presente" do
    Capture.subscribe_status()
    detector_state = start_supervised!({Agent, fn -> true end})

    server =
      start_supervised!({
        CameraServer,
        name: nil,
        editorials_dir: temporary_editorials_dir(),
        presence_detector: fn -> Agent.get(detector_state, & &1) end,
        presence_poll_ms: 60_000,
        presence_debounce_ms: 20,
        disk_poll_ms: 60_000,
        disk_checker: fn _dir -> 10_000_000_000 end,
        tether_spawner: fn _state -> {:ok, nil, nil} end
      })

    wait_for_presence_check(server)
    assert {:ok, _} = GenServer.call(server, {:set_editorial, "Casamento", nil})

    send(server, :poll_presence)
    wait_for_presence_check(server)
    assert_receive {:capture_status, %{status: :running, armed_automatically: true}}, 500

    stopped = CameraServer.stop_capture(server)
    assert stopped.status == :idle
    assert stopped.operator_stopped == true
    assert :sys.get_state(server).desired == false

    # esvazia broadcasts anteriores para o refute abaixo so ver novos eventos
    flush_capture_status()

    send(server, :poll_presence)
    wait_for_presence_check(server)

    refute CameraServer.status(server).auto_arm_pending
    refute_receive {:capture_status, %{status: :running}}, 80
    assert CameraServer.status(server).operator_stopped
    assert CameraServer.status(server).status == :idle

    resumed = CameraServer.start_capture(server)
    assert resumed.status == :running
    assert resumed.operator_stopped == false
    assert resumed.armed_automatically == false
  end

  test "debounce cancela auto-arm se a camera some antes do prazo" do
    Capture.subscribe_status()
    detector_state = start_supervised!({Agent, fn -> false end})

    server =
      start_supervised!({
        CameraServer,
        name: nil,
        editorials_dir: temporary_editorials_dir(),
        presence_detector: fn -> Agent.get(detector_state, & &1) end,
        presence_poll_ms: 60_000,
        presence_debounce_ms: 200,
        disk_poll_ms: 60_000,
        disk_checker: fn _dir -> 10_000_000_000 end,
        tether_spawner: fn _state -> {:ok, nil, nil} end
      })

    wait_for_presence_check(server)
    assert {:ok, _} = GenServer.call(server, {:set_editorial, "Casamento", nil})

    Agent.update(detector_state, fn _ -> true end)
    send(server, :poll_presence)
    wait_for_presence_check(server)
    assert CameraServer.status(server).auto_arm_pending

    Agent.update(detector_state, fn _ -> false end)
    send(server, :poll_presence)
    wait_for_presence_check(server)

    refute CameraServer.status(server).auto_arm_pending
    refute_receive {:capture_status, %{status: :running}}, 300
    assert CameraServer.status(server).status == :idle
  end

  test "poll_disk transmite cancelamento e reagendamento de auto_arm_pending" do
    Capture.subscribe_status()

    disk_state =
      start_supervised!(
        Supervisor.child_spec({Agent, fn -> 10_000_000_000 end}, id: :auto_arm_disk)
      )

    server =
      start_supervised!({
        CameraServer,
        name: nil,
        editorials_dir: temporary_editorials_dir(),
        presence_detector: fn -> true end,
        presence_poll_ms: 60_000,
        presence_debounce_ms: 5_000,
        disk_poll_ms: 60_000,
        min_free_disk_bytes: 5_000_000_000,
        disk_checker: fn _dir -> Agent.get(disk_state, & &1) end,
        tether_spawner: fn _state -> {:ok, nil, nil} end
      })

    wait_for_presence_check(server)
    assert {:ok, _} = GenServer.call(server, {:set_editorial, "Casamento", nil})
    assert CameraServer.status(server).auto_arm_pending
    flush_capture_status()

    Agent.update(disk_state, fn _ -> 1_000_000_000 end)
    send(server, :poll_disk)
    _ = :sys.get_state(server)

    assert_receive {:capture_status, %{auto_arm_pending: false}}
    refute CameraServer.status(server).auto_arm_pending

    flush_capture_status()
    Agent.update(disk_state, fn _ -> 10_000_000_000 end)
    send(server, :poll_disk)
    _ = :sys.get_state(server)

    assert_receive {:capture_status, %{auto_arm_pending: true}}
    assert CameraServer.status(server).auto_arm_pending
  end

  test "auto_arm nao pronto transmite limpeza de auto_arm_pending" do
    Capture.subscribe_status()

    server =
      start_supervised!({
        CameraServer,
        name: nil,
        editorials_dir: temporary_editorials_dir(),
        presence_detector: fn -> true end,
        presence_poll_ms: 60_000,
        presence_debounce_ms: 5_000,
        disk_poll_ms: 60_000,
        disk_checker: fn _dir -> 10_000_000_000 end,
        tether_spawner: fn _state -> {:ok, nil, nil} end
      })

    wait_for_presence_check(server)
    assert {:ok, _} = GenServer.call(server, {:set_editorial, "Casamento", nil})
    assert CameraServer.status(server).auto_arm_pending

    debounce_ref = :sys.get_state(server).presence_debounce_ref
    flush_capture_status()

    :sys.replace_state(server, fn state ->
      %{state | camera_present: false}
    end)

    send(server, {:auto_arm, debounce_ref})
    _ = :sys.get_state(server)

    assert_receive {:capture_status, %{auto_arm_pending: false}}
    refute CameraServer.status(server).auto_arm_pending
    refute_receive {:capture_status, %{status: :running}}, 80
  end

  test "set_editorial agenda auto-arm quando a camera ja esta presente" do
    Capture.subscribe_status()

    server =
      start_supervised!({
        CameraServer,
        name: nil,
        editorials_dir: temporary_editorials_dir(),
        presence_detector: fn -> true end,
        presence_poll_ms: 60_000,
        presence_debounce_ms: 20,
        disk_poll_ms: 60_000,
        disk_checker: fn _dir -> 10_000_000_000 end,
        tether_spawner: fn _state -> {:ok, nil, nil} end
      })

    wait_for_presence_check(server)
    assert CameraServer.status(server).camera_present

    assert {:ok, _} = GenServer.call(server, {:set_editorial, "Ensaio", nil})
    assert CameraServer.status(server).auto_arm_pending
    assert_receive {:capture_status, %{status: :running, armed_automatically: true}}, 500
  end

  test "falha de spawn limpa desired e aplica cooldown sem reconexao fantasma" do
    Capture.subscribe_status()
    detector_state = start_supervised!({Agent, fn -> true end})

    server =
      start_supervised!({
        CameraServer,
        name: nil,
        editorials_dir: temporary_editorials_dir(),
        presence_detector: fn -> Agent.get(detector_state, & &1) end,
        presence_poll_ms: 60_000,
        presence_debounce_ms: 20,
        disk_poll_ms: 60_000,
        disk_checker: fn _dir -> 10_000_000_000 end,
        spawn_failure_cooldown_ms: 60_000,
        tether_spawner: fn _state -> {:error, "Falha ao iniciar captura tethered"} end
      })

    wait_for_presence_check(server)
    assert {:ok, _} = GenServer.call(server, {:set_editorial, "Casamento", nil})

    send(server, :poll_presence)
    wait_for_presence_check(server)

    assert_receive {:capture_status,
                    %{status: :error, message: "Falha ao iniciar captura tethered"}},
                   500

    state = :sys.get_state(server)
    assert state.desired == false
    assert state.watcher_pid == nil
    assert is_integer(state.auto_arm_cooldown_until)
    refute CameraServer.status(server).auto_arm_pending

    flush_capture_status()

    Agent.update(detector_state, fn _ -> false end)
    send(server, :poll_presence)
    wait_for_presence_check(server)

    refute_receive {:capture_status, %{status: :waiting_camera}}, 80
    assert CameraServer.status(server).status == :error
    assert :sys.get_state(server).desired == false

    Agent.update(detector_state, fn _ -> true end)
    send(server, :poll_presence)
    wait_for_presence_check(server)

    refute CameraServer.status(server).auto_arm_pending
    refute_receive {:capture_status, %{status: :running}}, 80
    assert CameraServer.status(server).status == :error
  end

  test "falha de spawn encerra o folder watcher se ele ja estava ativo" do
    Capture.subscribe_status()

    server =
      start_supervised!({
        CameraServer,
        name: nil,
        editorials_dir: temporary_editorials_dir(),
        presence_detector: fn -> true end,
        presence_poll_ms: 60_000,
        presence_debounce_ms: 20,
        disk_poll_ms: 60_000,
        disk_checker: fn _dir -> 10_000_000_000 end,
        spawn_failure_cooldown_ms: 60_000,
        tether_spawner: fn _state -> {:error, "Falha ao iniciar captura tethered"} end
      })

    wait_for_presence_check(server)
    assert {:ok, _} = GenServer.call(server, {:set_editorial, "Casamento", nil})
    assert_receive {:capture_status, %{status: :error}}, 500

    {:ok, fake_watcher} = Agent.start_link(fn -> :ok end)
    watcher_ref = Process.monitor(fake_watcher)

    :sys.replace_state(server, fn state ->
      %{
        state
        | watcher_pid: fake_watcher,
          status: :idle,
          message: nil,
          desired: false,
          auto_arm_cooldown_until: nil
      }
    end)

    status = CameraServer.start_capture(server)
    assert status.status == :error
    assert :sys.get_state(server).watcher_pid == nil

    assert_receive {:DOWN, ^watcher_ref, :process, ^fake_watcher, _reason}, 500
  end

  test "start_capture explicito limpa o cooldown de falha de spawn" do
    Capture.subscribe_status()

    server =
      start_supervised!({
        CameraServer,
        name: nil,
        editorials_dir: temporary_editorials_dir(),
        presence_detector: fn -> true end,
        presence_poll_ms: 60_000,
        presence_debounce_ms: 20,
        disk_poll_ms: 60_000,
        disk_checker: fn _dir -> 10_000_000_000 end,
        spawn_failure_cooldown_ms: 60_000,
        tether_spawner: fn _state -> {:error, "Falha ao iniciar captura tethered"} end
      })

    wait_for_presence_check(server)
    assert {:ok, _} = GenServer.call(server, {:set_editorial, "Casamento", nil})
    assert_receive {:capture_status, %{status: :error}}, 500

    :sys.replace_state(server, fn state ->
      %{state | tether_spawner: fn _state -> {:ok, nil, nil} end}
    end)

    resumed = CameraServer.start_capture(server)
    assert resumed.status == :running
    assert :sys.get_state(server).desired == true
    assert :sys.get_state(server).auto_arm_cooldown_until == nil
  end

  test "status running sem watcher reporta ingest_awareness unavailable" do
    Capture.subscribe_status()

    server =
      start_supervised!({
        CameraServer,
        name: nil,
        editorials_dir: temporary_editorials_dir(),
        presence_detector: fn -> true end,
        presence_poll_ms: 60_000,
        presence_debounce_ms: 20,
        disk_poll_ms: 60_000,
        disk_checker: fn _dir -> 10_000_000_000 end,
        tether_spawner: fn _state -> {:ok, nil, nil} end
      })

    wait_for_presence_check(server)
    assert {:ok, _} = GenServer.call(server, {:set_editorial, "Casamento", nil})
    assert_receive {:capture_status, %{status: :running}}, 500

    :sys.replace_state(server, &%{&1 | watcher_pid: nil})
    status = CameraServer.status(server)
    assert status.status == :running
    assert status.ingest_awareness == :unavailable
  end

  test "parada do watcher transmite ingest_awareness unavailable enquanto running" do
    Capture.subscribe_status()

    server =
      start_supervised!({
        CameraServer,
        name: nil,
        editorials_dir: temporary_editorials_dir(),
        presence_detector: fn -> true end,
        presence_poll_ms: 60_000,
        presence_debounce_ms: 20,
        disk_poll_ms: 60_000,
        disk_checker: fn _dir -> 10_000_000_000 end,
        tether_spawner: fn _state -> {:ok, nil, nil} end
      })

    wait_for_presence_check(server)
    assert {:ok, _} = GenServer.call(server, {:set_editorial, "Casamento", nil})
    assert_receive {:capture_status, %{status: :running}}, 500

    {:ok, fake_watcher} = Agent.start_link(fn -> :ok end)

    :sys.replace_state(server, fn state ->
      %{state | watcher_pid: fake_watcher}
    end)

    assert CameraServer.status(server).ingest_awareness == :available

    flush_capture_status()
    send(server, {:file_event, fake_watcher, :stop})
    _ = :sys.get_state(server)

    assert_receive {:capture_status, %{status: :running, ingest_awareness: :unavailable}}

    assert :sys.get_state(server).watcher_pid == nil
    if Process.alive?(fake_watcher), do: Agent.stop(fake_watcher)
  end

  test "demo off: status.demo false e demo_fire recusado" do
    server =
      start_supervised!({
        CameraServer,
        name: nil,
        editorials_dir: temporary_editorials_dir(),
        demo: false,
        presence_detector: fn -> true end,
        presence_poll_ms: 60_000,
        disk_poll_ms: 60_000,
        disk_checker: fn _dir -> 42_000_000_000 end
      })

    wait_for_presence_check(server)

    assert CameraServer.status(server).demo == false
    assert CameraServer.demo?(server) == false
    assert {:error, :not_demo} = CameraServer.demo_fire(server)
  end

  test "demo on: camera_present true, arma sem gphoto2, fire grava JPEG e ingere" do
    editorials_dir = temporary_editorials_dir()
    folder = Path.join(editorials_dir, "2026-08-07 Demo 120000-1")
    File.mkdir_p!(folder)
    {:ok, _editorial} = Capture.start_editorial("Demo", folder)
    Capture.subscribe_photos()

    server =
      start_supervised!({
        CameraServer,
        name: nil,
        editorials_dir: editorials_dir,
        demo: true,
        presence_poll_ms: 60_000,
        disk_poll_ms: 60_000,
        disk_checker: fn _dir -> 42_000_000_000 end
      })

    wait_for_presence_check(server)

    assert CameraServer.status(server).demo == true
    assert CameraServer.status(server).camera_present == true

    status = CameraServer.start_capture(server)
    assert status.status == :running
    assert status.demo == true

    state = :sys.get_state(server)
    assert state.port == nil
    assert state.os_pid == nil
    assert state.desired == true

    assert {:error, :not_armed} =
             (
               CameraServer.stop_capture(server)
               CameraServer.demo_fire(server)
             )

    status = CameraServer.start_capture(server)
    assert status.status == :running

    assert {:ok, path} = CameraServer.demo_fire(server)
    assert path =~ ~r/\d{8}-\d{6}-001\.jpg$/
    assert File.exists?(path)
    assert File.stat!(path).size > 0

    assert {:ok, path2} = CameraServer.demo_fire(server)
    assert path2 =~ ~r/\d{8}-\d{6}-002\.jpg$/
    refute path == path2

    # caminho real: inotify → settle → ingest (ou settle manual se o watcher atrasar)
    assert_receive {:new_photo, _photo}, 5_000
  end

  test "demo on: stop desarma e D/demo_fire nao grava" do
    editorials_dir = temporary_editorials_dir()

    server =
      start_supervised!({
        CameraServer,
        name: nil,
        editorials_dir: editorials_dir,
        demo: true,
        presence_poll_ms: 60_000,
        disk_poll_ms: 60_000,
        disk_checker: fn _dir -> 42_000_000_000 end
      })

    wait_for_presence_check(server)
    assert CameraServer.start_capture(server).status == :running
    assert CameraServer.stop_capture(server).status == :idle
    assert :sys.get_state(server).desired == false
    assert {:error, :not_armed} = CameraServer.demo_fire(server)

    captures_dir = :sys.get_state(server).captures_dir
    assert File.ls!(captures_dir) == []
  end

  test "demo_fire devolve erro de escrita sem derrubar o GenServer" do
    editorials_dir = temporary_editorials_dir()

    server =
      start_supervised!({
        CameraServer,
        name: nil,
        editorials_dir: editorials_dir,
        demo: true,
        presence_poll_ms: 60_000,
        disk_poll_ms: 60_000,
        disk_checker: fn _dir -> 42_000_000_000 end
      })

    wait_for_presence_check(server)
    assert CameraServer.start_capture(server).status == :running

    captures_dir = :sys.get_state(server).captures_dir
    File.chmod!(captures_dir, 0o500)

    try do
      assert {:error, :eacces} = CameraServer.demo_fire(server)
      assert Process.alive?(server)
    after
      File.chmod!(captures_dir, 0o755)
    end
  end

  defp wait_for_presence_check(server) do
    case :sys.get_state(server).presence_check_ref do
      nil -> :ok
      _check_ref -> wait_for_presence_check(server)
    end
  end

  defp flush_capture_status do
    receive do
      {:capture_status, _status} -> flush_capture_status()
    after
      0 -> :ok
    end
  end

  defp temporary_editorials_dir do
    path =
      Path.join(
        System.tmp_dir!(),
        "revela-camera-server-#{System.unique_integer([:positive])}"
      )

    on_exit(fn -> File.rm_rf!(path) end)
    path
  end
end
