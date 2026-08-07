defmodule Revela.Capture.CameraServer do
  @moduledoc """
  Supervisiona o processo `gphoto2 --capture-tethered` e observa a pasta de
  downloads via inotify. Quando o fotografo dispara, o gphoto2 baixa a foto
  para a pasta observada; o watcher detecta o arquivo, espera ele terminar de
  escrever, e chama a ingestao.

  A pasta observada e a do editorial ativo (restaurada do banco no boot) ou o
  limbo `_sem-editorial` quando nao ha sessao. Trocar de editorial reserva uma
  pasta unica (`yyyy-mm-dd NOME HHMMSS-uid`) via `reserve_editorial_folder/1`
  antes de `Capture.start_editorial/2`, e so depois aponta a captura com
  `set_editorial/2`.

  Estado de captura (`status`):
    :idle           -> nao esta capturando
    :running        -> gphoto2 rodando, aguardando disparos
    :waiting_camera -> a camera usada na captura foi desconectada
    :reconnecting   -> o processo caiu com a camera presente e sera reiniciado
    :error          -> falha que nao se resolve sozinha
    :disk_full      -> parada preventiva por espaco em disco abaixo do minimo

  `camera_present` reflete se ha uma camera respondendo no USB agora, via
  `gphoto2 --auto-detect` (leitura, nao reivindica a interface). E checado
  periodicamente enquanto nao estamos capturando. O poll pausa durante :running
  para nao competir pela interface com o proprio gphoto2 do captura.

  Auto-arm: com editorial ativo, camera presente, disco OK (`disk_awareness`
  `:available` e acima do piso) e sem latch de stop do operador, a captura arma
  sozinha apos um debounce curto na borda USB (evita thrash do gphoto2). Sem
  editorial (limbo `_sem-editorial`) ou com `disk_awareness: :unavailable`, nao
  arma — exige clique. `stop_capture` gruda (`operator_stopped`); so
  `start_capture` libera o latch. Reconexao apos queda com `desired` permanece.
  Falha ao spawnar o tether limpa `desired` e arma um cooldown curto de auto-arm
  (sem reconexao fantasma nem tight-loop). Se o watcher de pasta nao sobe,
  `ingest_awareness` fica `:unavailable` enquanto `:running` para a UI Host
  mostrar tether degradado (arquivos no disco, sem ingestao). Status publico
  tambem expoe `armed_automatically` e `auto_arm_pending` para a UI Host.

  Espaco em disco (`free_disk_bytes`, `estimated_shots_left`, `disk_awareness`):
  o gphoto2 ignora SIGTERM, entao a parada normal manda SIGKILL nele (ver
  `kill_port/1`). Isso e seguro entre disparos, mas matar o processo no meio de
  uma transferencia PTP trava a camera de vez (so a bateria recupera). A parada
  por disco cheio (`maybe_stop_for_low_disk/1`) so age quando `pending` esta
  vazio (JPEG e RAW) e a janela de silencio pos-atividade de transferencia
  passou — cobrindo o intervalo entre o disparo e o primeiro evento inotify, e
  entre arquivos do mesmo disparo. Apos liberar espaco, o auto-arm pode remar
  (sem clique) se o contrato ainda valer. Se `:os_mon`/`:disksup` estiver
  ausente, `disk_awareness` fica `:unavailable` e a UI avisa (boot nao falha).

  Piso configuravel via opt `min_free_disk_bytes` ou env
  `TETHER_MIN_FREE_DISK_BYTES` (padrao 5 GiB). Ver README.
  """

  use GenServer
  require Logger

  alias Revela.Capture
  alias Revela.Capture.Ingest

  # tempo de "assentar" apos o ultimo evento do arquivo antes de processar
  @settle_ms 600

  # backoff de reconexao quando o gphoto2 cai com a captura ainda desejada
  @initial_backoff 2_000
  @max_backoff 15_000

  # intervalo do poll de presenca da camera (gphoto2 --auto-detect)
  @presence_poll_ms 3_000

  # debounce na borda USB presente→auto-arm (flaps curtos nao disparam gphoto2)
  @presence_debounce_ms 1_500

  # apos falha de spawn do tether: nao auto-armar de novo imediatamente
  @spawn_failure_cooldown_ms 15_000

  # piso de espaco livre em disco: abaixo disso a captura para sozinha, entre
  # disparos (nunca durante uma transferencia em curso). Motivacao: em
  # 2026-08-04 disco cheio + SIGKILL mid-PTP travou a Canon ate puxar bateria.
  @default_min_free_disk_bytes 5 * 1024 * 1024 * 1024

  # estimativa usada antes do primeiro disparo do editorial, quando ainda nao
  # ha arquivos na pasta para calcular a media real. Baseada na sessao de
  # 2026-08-04: RAW + JPEG da camera por disparo ficou em torno de 30 MB.
  @fallback_avg_bytes_per_shot 30 * 1024 * 1024

  # intervalo do poll de espaco em disco (fora do gatilho por disparo, que roda
  # a cada foto que assenta)
  @disk_poll_ms 15_000

  # janela minima sem atividade de transferencia (stdout do gphoto2, evento de
  # arquivo ou settle) antes de considerar seguro o SIGKILL por disco cheio.
  # Cobre o buraco entre o disparo e o primeiro inotify, e entre JPEG/RAW.
  @transfer_quiet_ms 2_500

  # ── API ─────────────────────────────────────────────────────────────────────

  def start_link(opts) do
    case Keyword.get(opts, :name, __MODULE__) do
      nil -> GenServer.start_link(__MODULE__, opts)
      name -> GenServer.start_link(__MODULE__, opts, name: name)
    end
  end

  def start_capture(server \\ __MODULE__), do: GenServer.call(server, :start_capture)
  def stop_capture(server \\ __MODULE__), do: GenServer.call(server, :stop_capture)
  def status(server \\ __MODULE__), do: GenServer.call(server, :status)

  @doc """
  Inicia um editorial: aponta a captura para `folder` (ou a pasta reservada /
  uma pasta unica nova) e passa a baixar as fotos para la. Para a captura
  atual (o usuario reinicia o captura em seguida).
  Retorna {:ok, %{name: name, folder: folder}}.
  """
  def set_editorial(name, folder \\ nil),
    do: GenServer.call(__MODULE__, {:set_editorial, name, folder})

  @doc """
  Cria a pasta unica do editorial e desliga captura/watcher/settles da pasta
  antiga, sem ainda apontar `captures_dir` para a nova. Use antes de
  `Capture.start_editorial/2` e passe a pasta retornada a `set_editorial/2`.
  """
  def reserve_editorial_folder(name),
    do: GenServer.call(__MODULE__, {:reserve_editorial_folder, name})

  @doc "Finaliza o editorial atual: para a captura e volta ao estado sem editorial. Os originais ficam na pasta."
  def finish_editorial, do: GenServer.call(__MODULE__, :finish_editorial)

  # ── GenServer ────────────────────────────────────────────────────────────────

  @impl true
  def init(opts) do
    # base onde ficam as pastas de cada editorial (yyyy-mm-dd NOME HHMMSS-uid)
    editorials_base =
      opts[:editorials_dir] ||
        Application.get_env(:revela, :editorials_dir) ||
        Path.join(File.cwd!(), "editorials")

    File.mkdir_p!(editorials_base)

    {editorial, captures_dir} = restore_active_editorial(editorials_base)

    state = %{
      status: :idle,
      message: nil,
      editorials_base: editorials_base,
      editorial: editorial,
      reserved_folder: nil,
      captures_dir: captures_dir,
      port: nil,
      os_pid: nil,
      watcher_pid: nil,
      # o usuario quer capturar? controla a reconexao automatica
      desired: false,
      # stop explicito do operador: impede auto-arm ate start_capture
      operator_stopped: false,
      # true quando o tether subiu via auto-arm (UI honestidade)
      armed_automatically: false,
      # monotonic ms: ate quando o auto-arm fica bloqueado apos falha de spawn
      auto_arm_cooldown_until: nil,
      spawn_failure_cooldown_ms:
        Keyword.get(opts, :spawn_failure_cooldown_ms, @spawn_failure_cooldown_ms),
      backoff_ms: @initial_backoff,
      # ha uma camera respondendo no USB agora? (ver poll de presenca)
      camera_present: false,
      presence_detector: Keyword.get(opts, :presence_detector, &detect_camera_present?/0),
      presence_poll_ms: Keyword.get(opts, :presence_poll_ms, @presence_poll_ms),
      presence_debounce_ms: Keyword.get(opts, :presence_debounce_ms, @presence_debounce_ms),
      presence_check_ref: nil,
      presence_timer: nil,
      presence_debounce_ref: nil,
      # opcional em testes: fn state -> {:ok, port, os_pid} | {:error, message}
      tether_spawner: Keyword.get(opts, :tether_spawner, &default_tether_spawner/1),
      # arquivos aguardando "assentar": %{path => timer_ref}. Nao vazio == ha
      # uma transferencia do gphoto2 em curso; nunca mata o processo nesse estado.
      # Inclui JPEG e RAW (.cr2/.cr3) so para gating de parada; so JPEG e ingerido.
      pending: %{},
      processed: MapSet.new(),
      disk_checker: Keyword.get(opts, :disk_checker, &default_disk_checker/1),
      min_free_disk_bytes: min_free_disk_bytes(opts),
      disk_poll_ms: Keyword.get(opts, :disk_poll_ms, @disk_poll_ms),
      transfer_quiet_ms: Keyword.get(opts, :transfer_quiet_ms, @transfer_quiet_ms),
      last_transfer_at: nil,
      quiet_disk_check_ref: nil,
      free_disk_bytes: nil,
      estimated_shots_left: nil,
      # :available quando o disk_checker devolve bytes; :unavailable quando
      # :os_mon/:disksup falta ou falha (parada preventiva fica desligada).
      disk_awareness: :unavailable
    }

    state = update_disk_status(state)
    Process.send_after(self(), :poll_disk, state.disk_poll_ms)
    send(self(), :poll_presence)
    {:ok, state}
  end

  @impl true
  def handle_call(:status, _from, state) do
    {:reply, public_status(state), state}
  end

  # sem camera detectada, mantem a captura parada e nao arma reconexao
  def handle_call(:start_capture, _from, %{camera_present: false} = state) do
    state = %{
      state
      | desired: false,
        operator_stopped: false,
        armed_automatically: false,
        auto_arm_cooldown_until: nil,
        status: :idle,
        message: nil
    }

    state = cancel_auto_arm_debounce(state)
    broadcast(state)
    {:reply, public_status(state), state}
  end

  def handle_call(:start_capture, _from, state) do
    state =
      cancel_auto_arm_debounce(%{
        state
        | desired: true,
          operator_stopped: false,
          armed_automatically: false,
          auto_arm_cooldown_until: nil
      })

    {_reply, state} = do_start(state)
    {:reply, public_status(state), state}
  end

  def handle_call(:stop_capture, _from, state) do
    state =
      state
      |> cancel_auto_arm_debounce()
      |> kill_port()
      |> Map.merge(%{
        desired: false,
        operator_stopped: true,
        armed_automatically: false,
        status: :idle,
        message: nil,
        backoff_ms: @initial_backoff
      })
      |> schedule_presence_poll(0)

    broadcast(state)
    {:reply, public_status(state), state}
  end

  def handle_call({:reserve_editorial_folder, name}, _from, state) do
    state = detach_capture(state)
    state = %{state | status: :idle, message: nil, armed_automatically: false}
    state = schedule_presence_poll(state, 0)

    folder = editorial_folder(state.editorials_base, name)
    File.mkdir_p!(folder)
    state = %{state | reserved_folder: folder}
    broadcast(state)
    {:reply, {:ok, %{name: name, folder: folder}}, state}
  end

  def handle_call({:set_editorial, name, folder}, _from, state) do
    state = detach_capture(state)

    folder = resolve_editorial_folder(folder, state, name)
    File.mkdir_p!(folder)

    state = %{
      state
      | captures_dir: folder,
        editorial: name,
        reserved_folder: nil,
        status: :idle,
        message: nil,
        armed_automatically: false,
        processed: MapSet.new()
    }

    state =
      state
      |> update_disk_status()
      |> schedule_presence_poll(0)
      |> maybe_schedule_auto_arm()

    broadcast(state)
    Logger.info("Editorial iniciado: #{name} (#{folder})")
    {:reply, {:ok, %{name: name, folder: folder}}, state}
  end

  def handle_call(:finish_editorial, _from, state) do
    state = detach_capture(state)
    limbo = Path.join(state.editorials_base, "_sem-editorial")
    File.mkdir_p!(limbo)

    state = %{
      state
      | editorial: nil,
        reserved_folder: nil,
        captures_dir: limbo,
        status: :idle,
        message: nil,
        armed_automatically: false,
        processed: MapSet.new()
    }

    state =
      state
      |> cancel_auto_arm_debounce()
      |> update_disk_status()
      |> schedule_presence_poll(0)

    broadcast(state)
    Logger.info("Editorial finalizado")
    {:reply, public_status(state), state}
  end

  # gphoto2 encerrou (camera desconectou, erro, etc.)
  @impl true
  def handle_info({port, {:exit_status, code}}, %{port: port} = state) do
    Logger.warning("gphoto2 encerrou com codigo #{code}")
    state = %{state | port: nil, os_pid: nil}

    if state.desired do
      state =
        state
        |> Map.merge(%{
          status: :reconnecting,
          message: "Conexão interrompida. Verificando a câmera..."
        })
        |> schedule_presence_poll(0)

      broadcast(state)
      {:noreply, state}
    else
      state = %{state | status: :idle, message: nil}
      broadcast(state)
      {:noreply, state}
    end
  end

  # tentativas agendadas e antigas nao reiniciam uma captura cancelada
  def handle_info(
        :reconnect,
        %{desired: true, camera_present: true, status: :reconnecting} = state
      ) do
    {_reply, state} = do_start(%{state | status: :idle, message: nil})
    {:noreply, state}
  end

  def handle_info(:reconnect, state), do: {:noreply, state}

  def handle_info({:auto_arm, debounce_ref}, %{presence_debounce_ref: debounce_ref} = state) do
    previous = public_status(state)
    state = %{state | presence_debounce_ref: nil}

    if auto_arm_ready?(state) do
      {_reply, state} = do_start(%{state | desired: true, armed_automatically: true})
      {:noreply, state}
    else
      broadcast_if_changed(previous, state)
      {:noreply, state}
    end
  end

  def handle_info({:auto_arm, _stale_ref}, state), do: {:noreply, state}

  # o auto-detect roda fora do GenServer porque pode levar alguns segundos
  def handle_info(:poll_presence, %{status: :running} = state) do
    {:noreply, %{state | presence_timer: nil}}
  end

  def handle_info(:poll_presence, %{presence_check_ref: nil} = state) do
    parent = self()
    detector = state.presence_detector
    check_ref = make_ref()

    Task.start(fn ->
      send(parent, {:presence, check_ref, run_presence_detector(detector)})
    end)

    {:noreply, %{state | presence_check_ref: check_ref, presence_timer: nil}}
  end

  def handle_info(:poll_presence, state), do: {:noreply, %{state | presence_timer: nil}}

  def handle_info(
        {:presence, check_ref, _present?},
        %{status: :running, presence_check_ref: check_ref} = state
      ) do
    {:noreply, %{state | presence_check_ref: nil}}
  end

  def handle_info(
        {:presence, check_ref, present?},
        %{presence_check_ref: check_ref} = state
      ) do
    previous = public_status(state)
    state = %{state | camera_present: present?, presence_check_ref: nil}

    state = transition_after_presence_check(state)
    broadcast_if_changed(previous, state)
    {:noreply, schedule_presence_poll_unless_running(state)}
  end

  def handle_info({:presence, _check_ref, _present?}, state), do: {:noreply, state}

  # saida de texto do gphoto2 (log de disparos); marca atividade de transferencia
  # para a janela quiet — o stdout costuma chegar antes do inotify do arquivo.
  def handle_info({port, {:data, data}}, %{port: port} = state) do
    data = String.trim(data)
    log_gphoto2(data)

    state =
      if data == "" do
        state
      else
        state
        |> note_transfer_activity()
        |> maybe_schedule_quiet_disk_check()
      end

    {:noreply, state}
  end

  # evento do watcher de arquivos
  def handle_info({:file_event, watcher, {path, _events}}, %{watcher_pid: watcher} = state) do
    if transfer_candidate?(path) and not MapSet.member?(state.processed, path) do
      if ref = state.pending[path], do: Process.cancel_timer(ref)
      ref = Process.send_after(self(), {:settle, path}, @settle_ms)

      state =
        state
        |> note_transfer_activity()
        |> Map.put(:pending, Map.put(state.pending, path, ref))

      {:noreply, state}
    else
      {:noreply, state}
    end
  end

  def handle_info({:file_event, watcher, :stop}, %{watcher_pid: watcher} = state) do
    previous = public_status(state)
    state = %{state | watcher_pid: nil}
    broadcast_if_changed(previous, state)
    {:noreply, state}
  end

  # arquivo assentou: processa JPEG uma unica vez; RAW so sai do pending
  def handle_info({:settle, path}, state) do
    case Map.pop(state.pending, path) do
      {nil, _pending} ->
        {:noreply, state}

      {_ref, pending} ->
        state =
          %{state | pending: pending}
          |> note_transfer_activity()

        state =
          cond do
            MapSet.member?(state.processed, path) ->
              state

            not under_captures_dir?(path, state.captures_dir) ->
              state

            true ->
              settle_file(path, state)
          end

        state =
          state
          |> note_transfer_activity()
          |> check_disk_between_shots()
          |> maybe_schedule_quiet_disk_check()

        {:noreply, state}
    end
  end

  # poll de fundo: cobre o caso de o disco encher sem novos disparos (ou antes
  # do primeiro). So efetivamente para a captura se nao houver transferencia
  # em curso (ver maybe_stop_for_low_disk/1).
  def handle_info(:poll_disk, state) do
    state = check_disk_between_shots(state)
    previous = public_status(state)
    state = maybe_schedule_auto_arm(state)
    broadcast_if_changed(previous, state)
    Process.send_after(self(), :poll_disk, state.disk_poll_ms)
    {:noreply, state}
  end

  def handle_info({:quiet_disk_check, check_ref}, %{quiet_disk_check_ref: check_ref} = state) do
    state = %{state | quiet_disk_check_ref: nil}
    {:noreply, check_disk_between_shots(state)}
  end

  def handle_info({:quiet_disk_check, _stale_ref}, state), do: {:noreply, state}

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    kill_port(state)
    :ok
  end

  # ── helpers ──────────────────────────────────────────────────────────────────

  defp do_start(%{status: :running} = state), do: {public_status(state), state}

  defp do_start(state) do
    state = update_disk_status(state)

    cond do
      disk_below_minimum?(state) ->
        message = low_disk_message(state)

        state =
          %{
            state
            | desired: false,
              armed_automatically: false,
              status: :disk_full,
              message: message,
              backoff_ms: @initial_backoff
          }
          |> schedule_presence_poll(0)

        broadcast(state)

        Logger.warning(
          "Recusa iniciar captura: espaco livre (#{state.free_disk_bytes} bytes) " <>
            "abaixo do minimo (#{state.min_free_disk_bytes} bytes)"
        )

        {public_status(state), state}

      true ->
        state = ensure_watcher(state)

        case run_tether_spawner(state) do
          {:ok, port, os_pid} ->
            state = %{
              state
              | port: port,
                os_pid: os_pid,
                status: :running,
                message: nil,
                backoff_ms: @initial_backoff
            }

            state = cancel_presence_poll(state)
            broadcast(state)

            Logger.info(
              "Captura iniciado (gphoto2 pid #{inspect(os_pid)}) em #{state.captures_dir}" <>
                if(state.armed_automatically, do: " [auto-arm]", else: "")
            )

            {public_status(state), state}

          {:error, message} ->
            now = System.monotonic_time(:millisecond)

            state =
              %{
                state
                | desired: false,
                  armed_automatically: false,
                  status: :error,
                  message: message,
                  auto_arm_cooldown_until: now + state.spawn_failure_cooldown_ms,
                  backoff_ms: @initial_backoff
              }
              |> stop_watcher()
              |> cancel_auto_arm_debounce()
              |> schedule_presence_poll(0)

            broadcast(state)
            {public_status(state), state}
        end
    end
  end

  defp run_tether_spawner(state) do
    case state.tether_spawner.(state) do
      {:ok, port, os_pid} -> {:ok, port, os_pid}
      {:error, message} when is_binary(message) -> {:error, message}
      _other -> {:error, "Falha ao iniciar captura tethered"}
    end
  rescue
    _error -> {:error, "Falha ao iniciar captura tethered"}
  catch
    _kind, _reason -> {:error, "Falha ao iniciar captura tethered"}
  end

  defp default_tether_spawner(state) do
    case System.find_executable("gphoto2") do
      nil ->
        {:error, "gphoto2 não encontrado no PATH"}

      gphoto2 ->
        release_gvfs()

        port =
          Port.open(
            {:spawn_executable, gphoto2},
            [
              :binary,
              :exit_status,
              :stderr_to_stdout,
              cd: state.captures_dir,
              args: [
                "--capture-tethered",
                "--filename",
                "%Y%m%d-%H%M%S-%03n.%C",
                "--force-overwrite"
              ]
            ]
          )

        os_pid = port |> Port.info(:os_pid) |> elem(1)
        {:ok, port, os_pid}
    end
  end

  defp transition_after_presence_check(%{camera_present: false, desired: true} = state) do
    state = cancel_auto_arm_debounce(state)

    %{
      state
      | status: :waiting_camera,
        message: "Câmera desconectada. Reconecte o cabo USB para retomar.",
        backoff_ms: @initial_backoff
    }
  end

  defp transition_after_presence_check(
         %{
           camera_present: true,
           desired: true,
           status: :waiting_camera
         } = state
       ) do
    state = cancel_auto_arm_debounce(state)
    {_reply, state} = do_start(%{state | status: :idle, message: nil})
    state
  end

  defp transition_after_presence_check(
         %{
           camera_present: true,
           desired: true,
           status: :reconnecting
         } = state
       ) do
    state = cancel_auto_arm_debounce(state)
    Process.send_after(self(), :reconnect, state.backoff_ms)
    delay_seconds = div(state.backoff_ms, 1_000)

    %{
      state
      | message: "Conexão interrompida. Nova tentativa em #{delay_seconds}s.",
        backoff_ms: min(state.backoff_ms * 2, @max_backoff)
    }
  end

  defp transition_after_presence_check(%{camera_present: false} = state) do
    cancel_auto_arm_debounce(state)
  end

  defp transition_after_presence_check(state), do: maybe_schedule_auto_arm(state)

  defp auto_arm_ready?(state) do
    not state.operator_stopped and
      is_binary(state.editorial) and
      state.camera_present and
      not state.desired and
      state.status not in [:running, :reconnecting, :waiting_camera] and
      state.disk_awareness == :available and
      not disk_below_minimum?(state) and
      auto_arm_cooldown_clear?(state)
  end

  defp auto_arm_cooldown_clear?(%{auto_arm_cooldown_until: nil}), do: true

  defp auto_arm_cooldown_clear?(state) do
    System.monotonic_time(:millisecond) >= state.auto_arm_cooldown_until
  end

  defp maybe_schedule_auto_arm(state) do
    if auto_arm_ready?(state) do
      schedule_auto_arm_debounce(state)
    else
      cancel_auto_arm_debounce(state)
    end
  end

  defp schedule_auto_arm_debounce(%{presence_debounce_ref: ref} = state) when is_reference(ref),
    do: state

  defp schedule_auto_arm_debounce(state) do
    debounce_ref = make_ref()
    Process.send_after(self(), {:auto_arm, debounce_ref}, state.presence_debounce_ms)
    %{state | presence_debounce_ref: debounce_ref}
  end

  defp cancel_auto_arm_debounce(%{presence_debounce_ref: nil} = state), do: state

  defp cancel_auto_arm_debounce(%{presence_debounce_ref: _ref} = state) do
    # timers are cancelled by ignoring stale refs in handle_info; clear the latch
    %{state | presence_debounce_ref: nil}
  end

  defp schedule_presence_poll_unless_running(%{status: :running} = state),
    do: cancel_presence_poll(state)

  defp schedule_presence_poll_unless_running(
         %{
           status: :reconnecting,
           camera_present: true
         } = state
       ),
       do: cancel_presence_poll(state)

  defp schedule_presence_poll_unless_running(state), do: schedule_presence_poll(state)

  defp schedule_presence_poll(state, delay_ms \\ nil) do
    state = cancel_presence_poll(state)
    delay_ms = delay_ms || state.presence_poll_ms
    timer = Process.send_after(self(), :poll_presence, delay_ms)
    %{state | presence_timer: timer}
  end

  defp cancel_presence_poll(%{presence_timer: nil} = state), do: state

  defp cancel_presence_poll(%{presence_timer: timer} = state) do
    Process.cancel_timer(timer)
    %{state | presence_timer: nil}
  end

  defp run_presence_detector(detector) do
    detector.() == true
  rescue
    _error -> false
  catch
    _kind, _reason -> false
  end

  defp detect_camera_present? do
    with gphoto2 when is_binary(gphoto2) <- System.find_executable("gphoto2"),
         {output, 0} <- System.cmd(gphoto2, ["--auto-detect"], stderr_to_stdout: true) do
      output
      |> String.split("\n", trim: true)
      |> Enum.drop_while(&(not String.starts_with?(String.trim(&1), "---")))
      |> Enum.drop(1)
      |> Enum.any?(&(String.trim(&1) != ""))
    else
      _error -> false
    end
  rescue
    _error -> false
  end

  defp detach_capture(state) do
    state
    |> cancel_auto_arm_debounce()
    |> kill_port()
    |> stop_watcher()
    |> clear_pending()
    |> Map.merge(%{desired: false, backoff_ms: @initial_backoff})
  end

  # encerra o watcher da pasta atual (para trocar de editorial/pasta)
  defp stop_watcher(%{watcher_pid: pid} = state) when is_pid(pid) do
    if Process.alive?(pid), do: GenServer.stop(pid, :normal)
    %{state | watcher_pid: nil}
  end

  defp stop_watcher(state), do: state

  defp clear_pending(%{pending: pending} = state) do
    Enum.each(pending, fn {_path, ref} -> Process.cancel_timer(ref) end)
    %{state | pending: %{}}
  end

  defp under_captures_dir?(path, captures_dir) do
    path = Path.expand(path)
    dir = Path.expand(captures_dir)
    String.starts_with?(path, dir <> "/")
  end

  # nome seguro para pasta: remove separadores e caracteres de controle
  defp sanitize(name) do
    name
    |> to_string()
    |> String.replace(~r/[\/\\:*?"<>|\x00-\x1f]/, "-")
    |> String.trim()
    |> case do
      "" -> "editorial"
      s -> s
    end
  end

  defp restore_active_editorial(editorials_base) do
    case Capture.current_editorial() do
      %{name: name, folder: folder} when is_binary(folder) and folder != "" ->
        File.mkdir_p!(folder)
        {name, folder}

      _ ->
        limbo = Path.join(editorials_base, "_sem-editorial")
        File.mkdir_p!(limbo)
        {nil, limbo}
    end
  end

  defp resolve_editorial_folder(folder, _state, _name) when is_binary(folder) and folder != "" do
    folder
  end

  defp resolve_editorial_folder(_folder, %{reserved_folder: reserved}, _name)
       when is_binary(reserved) do
    reserved
  end

  defp resolve_editorial_folder(_folder, state, name) do
    editorial_folder(state.editorials_base, name)
  end

  defp editorial_folder(editorials_base, name) do
    {{y, m, d}, {h, min, s}} = :calendar.local_time()
    date = :io_lib.format("~4..0B-~2..0B-~2..0B", [y, m, d]) |> to_string()
    time = :io_lib.format("~2..0B~2..0B~2..0B", [h, min, s]) |> to_string()
    uid = System.unique_integer([:positive])
    Path.join(editorials_base, "#{date} #{sanitize(name)} #{time}-#{uid}")
  end

  defp ensure_watcher(%{watcher_pid: pid} = state) when is_pid(pid), do: state

  defp ensure_watcher(state) do
    case FileSystem.start_link(dirs: [state.captures_dir]) do
      {:ok, pid} ->
        FileSystem.subscribe(pid)
        %{state | watcher_pid: pid}

      :ignore ->
        Logger.warning(
          "file_system watcher indisponivel (inotify); tether sobe sem ingestao por pasta"
        )

        state

      {:error, reason} ->
        Logger.warning("file_system watcher falhou: #{inspect(reason)}")
        state
    end
  end

  defp kill_port(%{port: nil} = state), do: state

  defp kill_port(%{port: port, os_pid: os_pid} = state) do
    # gphoto2 --capture-tethered ignora SIGTERM; SIGKILL garante que nao vire orfao
    if os_pid,
      do: System.cmd("kill", ["-KILL", Integer.to_string(os_pid)], stderr_to_stdout: true)

    if is_port(port) and Port.info(port), do: Port.close(port)
    %{state | port: nil, os_pid: nil}
  end

  # Libera a camera do gvfs, que a monta e reivindica a interface USB automaticamente
  # ("interface 0 ocupada"). Desmonta e encerra o monitor/daemon do gvfs; assim que o
  # gphoto2 assume a interface na sequencia, o gvfs nao consegue mais rouba-la na sessao.
  defp release_gvfs do
    System.cmd("gio", ["mount", "-s", "gphoto2"], stderr_to_stdout: true)
    System.cmd("pkill", ["-f", "gvfsd-gphoto2"], stderr_to_stdout: true)
    System.cmd("pkill", ["-f", "gvfs-gphoto2-volume-monitor"], stderr_to_stdout: true)
    # pequena folga para o dispositivo ser liberado antes do gphoto2 assumir
    Process.sleep(300)
  rescue
    _ -> :ok
  end

  defp transfer_candidate?(path) do
    ext = path |> Path.extname() |> String.downcase()
    ext in [".jpg", ".jpeg", ".cr2", ".cr3"]
  end

  defp jpeg_path?(path) do
    ext = path |> Path.extname() |> String.downcase()
    ext in [".jpg", ".jpeg"]
  end

  defp raw_path?(path) do
    ext = path |> Path.extname() |> String.downcase()
    ext in [".cr2", ".cr3"]
  end

  defp settle_file(path, state) do
    cond do
      jpeg_path?(path) ->
        case Ingest.process(path) do
          {:ok, _photo} ->
            %{state | processed: MapSet.put(state.processed, path)}

          :ignore ->
            state

          {:error, _reason} ->
            # deixa fora do processed para permitir nova tentativa em evento futuro
            state
        end

      raw_path?(path) ->
        # RAW so entra em pending para nao SIGKILL no meio do PTP; nao ingerir.
        %{state | processed: MapSet.put(state.processed, path)}

      true ->
        state
    end
  end

  defp log_gphoto2(""), do: :ok
  defp log_gphoto2(text), do: Logger.debug("[gphoto2] #{text}")

  defp public_status(state) do
    %{
      status: state.status,
      message: state.message,
      editorial: state.editorial,
      camera_present: state.camera_present,
      operator_stopped: state.operator_stopped,
      armed_automatically: state.armed_automatically,
      auto_arm_pending: is_reference(state.presence_debounce_ref),
      ingest_awareness: ingest_awareness(state),
      free_disk_bytes: state.free_disk_bytes,
      estimated_shots_left: state.estimated_shots_left,
      disk_awareness: state.disk_awareness
    }
  end

  defp ingest_awareness(%{status: :running, watcher_pid: pid}) when is_pid(pid), do: :available
  defp ingest_awareness(%{status: :running}), do: :unavailable
  defp ingest_awareness(_state), do: :available

  defp broadcast_if_changed(previous, state) do
    if previous != public_status(state), do: broadcast(state)
  end

  defp broadcast(state), do: Capture.broadcast_status(public_status(state))

  # ── espaco em disco ──────────────────────────────────────────────────────────

  # atualiza free_disk_bytes/estimated_shots_left e, se preciso, para a captura.
  # Usado nos dois gatilhos: apos cada foto assentar e no poll periodico.
  defp check_disk_between_shots(state) do
    previous = public_status(state)
    state = state |> update_disk_status() |> maybe_stop_for_low_disk()
    broadcast_if_changed(previous, state)
    state
  end

  # so recalcula os numeros; nao decide nem para a captura (usado tambem ao
  # trocar de editorial, onde a captura ja esta parada).
  defp update_disk_status(state) do
    case run_disk_checker(state.disk_checker, state.captures_dir) do
      free_bytes when is_integer(free_bytes) ->
        avg_bytes =
          case avg_bytes_per_shot(state.captures_dir) do
            avg when is_number(avg) and avg > 0 -> avg
            _other -> @fallback_avg_bytes_per_shot
          end

        estimated_shots = max(div(free_bytes, max(trunc(avg_bytes), 1)), 0)

        %{
          state
          | free_disk_bytes: free_bytes,
            estimated_shots_left: estimated_shots,
            disk_awareness: :available
        }

      :unavailable ->
        %{
          state
          | free_disk_bytes: nil,
            estimated_shots_left: nil,
            disk_awareness: :unavailable
        }
    end
  end

  # so para quando: capturando, espaco abaixo do piso, nenhuma transferencia
  # em curso (pending vazio) e janela quiet sem atividade recente. A quiet
  # window evita SIGKILL no buraco antes do primeiro inotify / entre JPEG-RAW.
  defp maybe_stop_for_low_disk(%{status: :running} = state) do
    cond do
      disk_below_minimum?(state) and safe_to_stop_for_disk?(state) ->
        Logger.warning(
          "Espaco livre (#{state.free_disk_bytes} bytes) abaixo do minimo configurado " <>
            "(#{state.min_free_disk_bytes} bytes); parando captura entre disparos"
        )

        message = low_disk_message(state)

        state
        |> kill_port()
        |> Map.merge(%{
          desired: false,
          status: :disk_full,
          message: message,
          backoff_ms: @initial_backoff
        })
        |> schedule_presence_poll(0)

      disk_below_minimum?(state) ->
        maybe_schedule_quiet_disk_check(state)

      true ->
        state
    end
  end

  defp maybe_stop_for_low_disk(state), do: state

  defp disk_below_minimum?(%{free_disk_bytes: free, min_free_disk_bytes: min})
       when is_integer(free),
       do: free < min

  defp disk_below_minimum?(_state), do: false

  defp safe_to_stop_for_disk?(%{pending: pending} = state) when map_size(pending) == 0 do
    transfer_quiet?(state)
  end

  defp safe_to_stop_for_disk?(_state), do: false

  defp note_transfer_activity(state) do
    state = cancel_quiet_disk_check(state)
    %{state | last_transfer_at: System.monotonic_time(:millisecond)}
  end

  defp transfer_quiet?(%{last_transfer_at: nil}), do: true

  defp transfer_quiet?(%{last_transfer_at: at, transfer_quiet_ms: quiet_ms}) do
    System.monotonic_time(:millisecond) - at >= quiet_ms
  end

  defp maybe_schedule_quiet_disk_check(
         %{status: :running, pending: pending, quiet_disk_check_ref: nil} = state
       )
       when map_size(pending) == 0 do
    check_ref = make_ref()
    Process.send_after(self(), {:quiet_disk_check, check_ref}, state.transfer_quiet_ms)
    %{state | quiet_disk_check_ref: check_ref}
  end

  defp maybe_schedule_quiet_disk_check(state), do: state

  defp cancel_quiet_disk_check(%{quiet_disk_check_ref: nil} = state), do: state

  defp cancel_quiet_disk_check(state), do: %{state | quiet_disk_check_ref: nil}

  defp low_disk_message(state) do
    gb = format_gb(state.free_disk_bytes)

    shots_hint =
      if is_integer(state.estimated_shots_left),
        do: ", cabem ~#{state.estimated_shots_left} fotos",
        else: ""

    "Espaço em disco abaixo do mínimo (~#{gb} GB livres#{shots_hint}). " <>
      "Captura parada entre disparos para proteger a câmera; libere espaço — " <>
      "o tether rearma automaticamente quando o espaço voltar."
  end

  defp format_gb(bytes) when is_integer(bytes), do: Float.round(bytes / 1_073_741_824, 1)
  defp format_gb(_bytes), do: "?"

  defp min_free_disk_bytes(opts) do
    Keyword.get(opts, :min_free_disk_bytes) ||
      parse_positive_int(System.get_env("TETHER_MIN_FREE_DISK_BYTES")) ||
      @default_min_free_disk_bytes
  end

  defp parse_positive_int(nil), do: nil

  defp parse_positive_int(str) do
    case Integer.parse(str) do
      {n, _rest} when n > 0 -> n
      _other -> nil
    end
  end

  defp run_disk_checker(checker, path) do
    case checker.(path) do
      free when is_integer(free) and free >= 0 -> free
      :unavailable -> :unavailable
      _other -> :unavailable
    end
  rescue
    _error -> :unavailable
  catch
    _kind, _reason -> :unavailable
  end

  # media real de bytes por disparo na pasta do editorial atual (soma RAW+JPEG
  # do mesmo stem), usada para traduzir espaco livre em "cabem ~N fotos".
  # nil quando a pasta ainda nao tem nenhum arquivo (editorial recem-criado).
  defp avg_bytes_per_shot(dir) do
    case File.ls(dir) do
      {:ok, entries} ->
        shot_sizes =
          entries
          |> Enum.reject(&String.starts_with?(&1, "."))
          |> Enum.map(&Path.join(dir, &1))
          |> Enum.filter(&File.regular?/1)
          |> Enum.reduce(%{}, fn path, acc ->
            case file_size(path) do
              nil ->
                acc

              size ->
                stem = path |> Path.basename() |> Path.rootname() |> String.downcase()
                Map.update(acc, stem, size, &(&1 + size))
            end
          end)
          |> Map.values()

        case shot_sizes do
          [] ->
            nil

          sizes ->
            avg = Enum.sum(sizes) / length(sizes)
            if avg > 0, do: avg, else: nil
        end

      {:error, _reason} ->
        nil
    end
  end

  defp file_size(path) do
    case File.stat(path) do
      {:ok, %File.Stat{size: size}} -> size
      {:error, _reason} -> nil
    end
  end

  # espaco livre do mount que contem `path`, em bytes. Usa :disksup.get_disk_info/1
  # (leitura ao vivo; get_disk_data/0 e cache de ate ~30 min). Inicia :os_mon sob
  # demanda; devolve :unavailable se o pacote nao estiver instalado.
  defp default_disk_checker(path) do
    case ensure_os_mon_started() do
      :ok -> fetch_live_free_disk_bytes(path)
      {:error, _reason} -> :unavailable
    end
  end

  defp fetch_live_free_disk_bytes(path) do
    path_chars = path |> Path.expand() |> String.to_charlist()

    case :disksup.get_disk_info(path_chars) do
      [{_id, 0, 0, 0}] ->
        :unavailable

      [{_id, _total_kib, avail_kib, _capacity}]
      when is_integer(avail_kib) and avail_kib >= 0 ->
        avail_kib * 1024

      _other ->
        :unavailable
    end
  end

  defp ensure_os_mon_started do
    case Application.ensure_all_started(:os_mon) do
      {:ok, _apps} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end
end
