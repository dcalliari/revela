defmodule Revela.Capture.CameraServer do
  @moduledoc """
  Supervisiona o processo `gphoto2 --capture-tethered` e observa a pasta de
  downloads via inotify. Quando o fotografo dispara, o gphoto2 baixa a foto
  para a pasta observada; o watcher detecta o arquivo, espera ele terminar de
  escrever, e chama a ingestao.

  Estado de captura (`status`):
    :idle           -> nao esta capturando
    :running        -> gphoto2 rodando, aguardando disparos
    :waiting_camera -> a camera usada na captura foi desconectada
    :reconnecting   -> o processo caiu com a camera presente e sera reiniciado
    :error          -> falha que nao se resolve sozinha

  `camera_present` reflete se ha uma camera respondendo no USB agora, via
  `gphoto2 --auto-detect` (leitura, nao reivindica a interface). E checado
  periodicamente enquanto nao estamos capturando. O poll pausa durante :running
  para nao competir pela interface com o proprio gphoto2 do captura.
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
      backoff_ms: @initial_backoff,
      # ha uma camera respondendo no USB agora? (ver poll de presenca)
      camera_present: false,
      presence_detector: Keyword.get(opts, :presence_detector, &detect_camera_present?/0),
      presence_poll_ms: Keyword.get(opts, :presence_poll_ms, @presence_poll_ms),
      presence_check_ref: nil,
      presence_timer: nil,
      # arquivos aguardando "assentar": %{path => timer_ref}
      pending: %{},
      processed: MapSet.new()
    }

    send(self(), :poll_presence)
    {:ok, state}
  end

  @impl true
  def handle_call(:status, _from, state) do
    {:reply, public_status(state), state}
  end

  # sem camera detectada, mantem a captura parada e nao arma reconexao
  def handle_call(:start_capture, _from, %{camera_present: false} = state) do
    state = %{state | desired: false, status: :idle, message: nil}
    broadcast(state)
    {:reply, public_status(state), state}
  end

  def handle_call(:start_capture, _from, state) do
    {_reply, state} = do_start(%{state | desired: true})
    {:reply, public_status(state), state}
  end

  def handle_call(:stop_capture, _from, state) do
    state = kill_port(%{state | desired: false, backoff_ms: @initial_backoff})
    state = state |> Map.merge(%{status: :idle, message: nil}) |> schedule_presence_poll(0)
    broadcast(state)
    {:reply, public_status(state), state}
  end

  def handle_call({:reserve_editorial_folder, name}, _from, state) do
    state = detach_capture(state)
    state = %{state | status: :idle, message: nil}
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
        processed: MapSet.new()
    }

    state = schedule_presence_poll(state, 0)
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
        processed: MapSet.new()
    }

    state = schedule_presence_poll(state, 0)
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

  # saida de texto do gphoto2 (log de disparos); apenas registra
  def handle_info({port, {:data, data}}, %{port: port} = state) do
    data |> String.trim() |> log_gphoto2()
    {:noreply, state}
  end

  # evento do watcher de arquivos
  def handle_info({:file_event, watcher, {path, _events}}, %{watcher_pid: watcher} = state) do
    if candidate?(path) and not MapSet.member?(state.processed, path) do
      if ref = state.pending[path], do: Process.cancel_timer(ref)
      ref = Process.send_after(self(), {:settle, path}, @settle_ms)
      {:noreply, %{state | pending: Map.put(state.pending, path, ref)}}
    else
      {:noreply, state}
    end
  end

  def handle_info({:file_event, watcher, :stop}, %{watcher_pid: watcher} = state) do
    {:noreply, %{state | watcher_pid: nil}}
  end

  # arquivo assentou: processa uma unica vez
  def handle_info({:settle, path}, state) do
    case Map.pop(state.pending, path) do
      {nil, _pending} ->
        {:noreply, state}

      {_ref, pending} ->
        state = %{state | pending: pending}

        cond do
          MapSet.member?(state.processed, path) ->
            {:noreply, state}

          not under_captures_dir?(path, state.captures_dir) ->
            {:noreply, state}

          true ->
            case Ingest.process(path) do
              {:ok, _photo} ->
                {:noreply, %{state | processed: MapSet.put(state.processed, path)}}

              :ignore ->
                {:noreply, state}

              {:error, _reason} ->
                # deixa fora do processed para permitir nova tentativa em evento futuro
                {:noreply, state}
            end
        end
    end
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    kill_port(state)
    :ok
  end

  # ── helpers ──────────────────────────────────────────────────────────────────

  defp do_start(%{status: :running} = state), do: {public_status(state), state}

  defp do_start(state) do
    case System.find_executable("gphoto2") do
      nil ->
        state = %{state | status: :error, message: "gphoto2 não encontrado no PATH"}
        broadcast(state)
        {public_status(state), state}

      gphoto2 ->
        release_gvfs()
        state = ensure_watcher(state)

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
        Logger.info("Captura iniciado (gphoto2 pid #{os_pid}) em #{state.captures_dir}")
        {public_status(state), state}
    end
  end

  defp transition_after_presence_check(%{camera_present: false, desired: true} = state) do
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
    Process.send_after(self(), :reconnect, state.backoff_ms)
    delay_seconds = div(state.backoff_ms, 1_000)

    %{
      state
      | message: "Conexão interrompida. Nova tentativa em #{delay_seconds}s.",
        backoff_ms: min(state.backoff_ms * 2, @max_backoff)
    }
  end

  defp transition_after_presence_check(state), do: state

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
    {:ok, pid} = FileSystem.start_link(dirs: [state.captures_dir])
    FileSystem.subscribe(pid)
    %{state | watcher_pid: pid}
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

  defp candidate?(path) do
    ext = path |> Path.extname() |> String.downcase()
    ext in [".jpg", ".jpeg"]
  end

  defp log_gphoto2(""), do: :ok
  defp log_gphoto2(text), do: Logger.debug("[gphoto2] #{text}")

  defp public_status(state) do
    %{
      status: state.status,
      message: state.message,
      editorial: state.editorial,
      camera_present: state.camera_present
    }
  end

  defp broadcast_if_changed(previous, state) do
    if previous != public_status(state), do: broadcast(state)
  end

  defp broadcast(state), do: Capture.broadcast_status(public_status(state))
end
