defmodule Revela.Capture.CameraServerTest do
  use ExUnit.Case, async: false

  alias Revela.Capture
  alias Revela.Capture.CameraServer

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

    assert CameraServer.start_capture(server) == %{
             camera_present: false,
             editorial: nil,
             message: nil,
             status: :idle
           }

    Agent.update(detector_state, fn _present? -> true end)
    send(server, :poll_presence)

    assert_receive {:capture_status, %{camera_present: true, status: :idle}}
    assert CameraServer.status(server).status == :idle
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

    assert {:ok, %{folder: folder}} = GenServer.call(server, {:set_editorial, "Casamento"})
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
    assert Process.read_timer(ref) == false

    send(server, {:settle, old_path})
    _ = :sys.get_state(server)

    assert :sys.get_state(server).processed == MapSet.new()
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

    assert {:ok, _} = GenServer.call(server, {:set_editorial, "Novo"})

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

  defp wait_for_presence_check(server) do
    case :sys.get_state(server).presence_check_ref do
      nil -> :ok
      _check_ref -> wait_for_presence_check(server)
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
