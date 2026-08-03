defmodule Revela.Capture.CameraServer do
  @moduledoc """
  Supervisiona o processo `gphoto2 --capture-tethered` e observa a pasta de
  downloads via inotify. Quando o fotografo dispara, o gphoto2 baixa a foto
  para a pasta observada; o watcher detecta o arquivo, espera ele terminar de
  escrever, e chama a ingestao.

  Estado de captura (`status`):
    :idle    -> nao esta capturando
    :running -> gphoto2 rodando, aguardando disparos
    :error   -> falhou ao iniciar (ex: camera ausente, gphoto2 nao encontrado)
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

  # ── API ─────────────────────────────────────────────────────────────────────

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  def start_capture, do: GenServer.call(__MODULE__, :start_capture)
  def stop_capture, do: GenServer.call(__MODULE__, :stop_capture)
  def status, do: GenServer.call(__MODULE__, :status)

  @doc """
  Inicia um editorial: cria a pasta "yyyy-mm-dd NOME" e passa a baixar as fotos
  para la. Para a captura atual (o usuario reinicia o captura em seguida).
  Retorna {:ok, %{name: name, folder: folder}}.
  """
  def set_editorial(name), do: GenServer.call(__MODULE__, {:set_editorial, name})

  @doc "Finaliza o editorial atual: para a captura e volta ao estado sem editorial. Os originais ficam na pasta."
  def finish_editorial, do: GenServer.call(__MODULE__, :finish_editorial)

  # ── GenServer ────────────────────────────────────────────────────────────────

  @impl true
  def init(opts) do
    # base onde ficam as pastas de cada editorial (yyyy-mm-dd NOME)
    editorials_base =
      opts[:editorials_dir] ||
        Application.get_env(:revela, :editorials_dir) ||
        Path.join(File.cwd!(), "editorials")

    File.mkdir_p!(editorials_base)

    # captures_dir e a pasta do editorial atual; ate escolher um, usa um limbo
    captures_dir = Path.join(editorials_base, "_sem-editorial")
    File.mkdir_p!(captures_dir)

    state = %{
      status: :idle,
      message: nil,
      editorials_base: editorials_base,
      editorial: nil,
      captures_dir: captures_dir,
      port: nil,
      os_pid: nil,
      watcher_pid: nil,
      # o usuario quer capturar? controla a reconexao automatica
      desired: false,
      backoff_ms: @initial_backoff,
      # arquivos aguardando "assentar": %{path => timer_ref}
      pending: %{},
      processed: MapSet.new()
    }

    {:ok, state}
  end

  @impl true
  def handle_call(:status, _from, state) do
    {:reply, public_status(state), state}
  end

  def handle_call(:start_capture, _from, state) do
    {_reply, state} = do_start(%{state | desired: true})
    {:reply, public_status(state), state}
  end

  def handle_call(:stop_capture, _from, state) do
    state = kill_port(%{state | desired: false, backoff_ms: @initial_backoff})
    state = %{state | status: :idle, message: nil}
    broadcast(state)
    {:reply, public_status(state), state}
  end

  def handle_call({:set_editorial, name}, _from, state) do
    # para a captura e o watcher da pasta antiga
    state = state |> kill_port() |> stop_watcher()
    state = %{state | desired: false, backoff_ms: @initial_backoff}

    {{y, m, d}, _} = :calendar.local_time()
    date = :io_lib.format("~4..0B-~2..0B-~2..0B", [y, m, d]) |> to_string()
    folder = Path.join(state.editorials_base, "#{date} #{sanitize(name)}")
    File.mkdir_p!(folder)

    state = %{
      state
      | captures_dir: folder,
        editorial: name,
        status: :idle,
        message: nil,
        processed: MapSet.new(),
        pending: %{}
    }

    broadcast(state)
    Logger.info("Editorial iniciado: #{name} (#{folder})")
    {:reply, {:ok, %{name: name, folder: folder}}, state}
  end

  def handle_call(:finish_editorial, _from, state) do
    state = state |> kill_port() |> stop_watcher()
    limbo = Path.join(state.editorials_base, "_sem-editorial")
    File.mkdir_p!(limbo)

    state = %{
      state
      | desired: false,
        backoff_ms: @initial_backoff,
        editorial: nil,
        captures_dir: limbo,
        status: :idle,
        message: nil,
        processed: MapSet.new(),
        pending: %{}
    }

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
      # captura ainda desejada: agenda reconexao com backoff crescente
      Process.send_after(self(), :reconnect, state.backoff_ms)
      next_backoff = min(state.backoff_ms * 2, @max_backoff)

      state = %{
        state
        | status: :reconnecting,
          message: "Camera caiu, reconectando em #{div(state.backoff_ms, 1000)}s...",
          backoff_ms: next_backoff
      }

      broadcast(state)
      {:noreply, state}
    else
      state = %{state | status: :idle, message: nil}
      broadcast(state)
      {:noreply, state}
    end
  end

  # tentativa de reconexao apos queda
  def handle_info(:reconnect, %{desired: true} = state) do
    {_reply, state} = do_start(%{state | status: :idle})
    {:noreply, state}
  end

  def handle_info(:reconnect, state), do: {:noreply, state}

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
    state = %{state | pending: Map.delete(state.pending, path)}

    if MapSet.member?(state.processed, path) do
      {:noreply, state}
    else
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
        state = %{state | status: :error, message: "gphoto2 nao encontrado no PATH"}
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

        broadcast(state)
        Logger.info("Captura iniciado (gphoto2 pid #{os_pid}) em #{state.captures_dir}")
        {public_status(state), state}
    end
  end

  # encerra o watcher da pasta atual (para trocar de editorial/pasta)
  defp stop_watcher(%{watcher_pid: pid} = state) when is_pid(pid) do
    if Process.alive?(pid), do: GenServer.stop(pid, :normal)
    %{state | watcher_pid: nil}
  end

  defp stop_watcher(state), do: state

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

  defp ensure_watcher(%{watcher_pid: pid} = state) when is_pid(pid), do: state

  defp ensure_watcher(state) do
    {:ok, pid} = FileSystem.start_link(dirs: [state.captures_dir])
    FileSystem.subscribe(pid)
    %{state | watcher_pid: pid}
  end

  defp kill_port(%{port: nil} = state), do: state

  defp kill_port(%{port: port, os_pid: os_pid} = state) do
    # gphoto2 --capture-tethered ignora SIGTERM; SIGKILL garante que nao vire orfao
    if os_pid, do: System.cmd("kill", ["-KILL", Integer.to_string(os_pid)], stderr_to_stdout: true)
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

  defp public_status(state),
    do: %{status: state.status, message: state.message, editorial: state.editorial}

  defp broadcast(state), do: Capture.broadcast_status(public_status(state))
end
