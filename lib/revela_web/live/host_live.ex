defmodule RevelaWeb.HostLive do
  @moduledoc """
  Tela de controle no laptop: QR code + URL da LAN para os celulares entrarem,
  status do captura (start/stop), estimativa de fotos restantes no disco,
  quem esta online e a agregacao de cores (consenso) de cada foto entre todos
  os revisores. Indisponibilidade do monitoramento de disco (:os_mon) nao
  aparece na UI — so um aviso no console do browser.

  No viewer imersivo, `follow` segue a mesma invariante que em `ReviewLive`
  (`follow == (idx == last)`); tecla `L`/`l` chama `go_live`. Demais atalhos
  (cores, setas, limpar) e a legenda ficam em `ViewerComponents`.
  """
  use RevelaWeb, :live_view

  alias Revela.Capture
  alias Revela.Capture.CameraServer
  alias RevelaWeb.{Colors, Presence, ViewerComponents}

  @recent 24

  # o host classifica com uma identidade fixa, sem pedir nome
  @host_id "host"
  @host_name "host"

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Capture.subscribe_photos()
      Capture.subscribe_labels()
      Capture.subscribe_status()
      Presence.subscribe()
    end

    url = review_url()

    capture = CameraServer.status()

    {:ok,
     socket
     |> assign(:url, url)
     |> assign(:qr, qr_svg(url))
     |> assign(:capture, capture)
     |> assign(:disk_warn_pushed, false)
     |> assign(:reviewers, Presence.list_reviewers())
     |> assign(:open, false)
     |> assign(:idx, 0)
     |> assign(:follow, true)
     |> assign(:notice, nil)
     |> assign(:labels, Capture.labels_for_reviewer(@host_id))
     |> load_photos()
     |> maybe_warn_disk(capture)}
  end

  @impl true
  def handle_event("start", _params, socket) do
    {:noreply, assign(socket, :capture, CameraServer.start_capture())}
  end

  def handle_event("stop", _params, socket) do
    {:noreply, assign(socket, :capture, CameraServer.stop_capture())}
  end

  # ── visualizador em tela cheia (host classifica como "host") ─────────────────

  def handle_event("open", %{"id" => id}, socket) do
    id = String.to_integer(id)
    last = max(length(socket.assigns.photos) - 1, 0)
    idx = Enum.find_index(socket.assigns.photos, &(&1.id == id)) || last
    {:noreply, socket |> assign(:open, true) |> navigate(idx)}
  end

  def handle_event("close", _params, socket) do
    {:noreply, assign(socket, open: false)}
  end

  # inicia um editorial: cria pasta unica da sessao, aponta a captura pra la
  # e limpa a tela para o novo conjunto
  def handle_event("start_editorial", %{"name" => name}, socket) do
    case String.trim(name) do
      "" ->
        {:noreply, socket}

      name ->
        {:ok, %{folder: folder}} = CameraServer.reserve_editorial_folder(name)
        {:ok, _editorial} = Capture.start_editorial(name, folder)
        {:ok, %{folder: ^folder}} = CameraServer.set_editorial(name, folder)

        {:noreply,
         socket
         |> assign(:capture, CameraServer.status())
         |> assign(:open, false)
         |> assign(:idx, 0)
         |> assign(:follow, true)
         |> assign(:labels, %{})
         |> assign(:notice, "Editorial \"#{name}\" iniciado. Originais em: #{folder}")
         |> load_photos()}
    end
  end

  # finaliza o editorial: para a captura e limpa a tela; originais e labels ficam
  def handle_event("finish_editorial", _params, socket) do
    CameraServer.finish_editorial()
    Capture.finish_editorial()

    {:noreply,
     socket
     |> assign(:capture, CameraServer.status())
     |> assign(:open, false)
     |> assign(:idx, 0)
     |> assign(:follow, true)
     |> assign(:labels, %{})
     |> assign(:notice, "Editorial finalizado. Os originais ficam salvos na pasta.")
     |> load_photos()}
  end

  def handle_event("pick", %{"color" => c}, socket) do
    color = String.to_integer(c)

    case current_photo(socket.assigns) do
      nil ->
        {:noreply, socket}

      photo ->
        Capture.set_label(photo.id, @host_id, @host_name, color)
        labels = Map.put(socket.assigns.labels, photo.id, color)
        last = max(length(socket.assigns.photos) - 1, 0)
        next_idx = min(socket.assigns.idx + 1, last)

        {:noreply,
         socket
         |> assign(:labels, labels)
         |> navigate(next_idx)}
    end
  end

  def handle_event("clear", _params, socket) do
    case current_photo(socket.assigns) do
      nil ->
        {:noreply, socket}

      photo ->
        Capture.clear_label(photo.id, @host_id)
        {:noreply, assign(socket, labels: Map.delete(socket.assigns.labels, photo.id))}
    end
  end

  def handle_event("prev", _params, socket) do
    {:noreply, navigate(socket, socket.assigns.idx - 1)}
  end

  def handle_event("next", _params, socket) do
    {:noreply, navigate(socket, socket.assigns.idx + 1)}
  end

  def handle_event("go_live", _params, socket) do
    last = max(length(socket.assigns.photos) - 1, 0)
    {:noreply, navigate(socket, last)}
  end

  def handle_event("key", %{"key" => key}, socket) do
    case key do
      k when k in ~w(1 2 3 4 5) ->
        handle_event("pick", %{"color" => Integer.to_string(String.to_integer(k) - 1)}, socket)

      "ArrowLeft" ->
        handle_event("prev", %{}, socket)

      "ArrowRight" ->
        handle_event("next", %{}, socket)

      "Escape" ->
        handle_event("close", %{}, socket)

      k when k in ["0", "Backspace", "Delete"] ->
        handle_event("clear", %{}, socket)

      k when k in ["l", "L"] ->
        handle_event("go_live", %{}, socket)

      _ ->
        {:noreply, socket}
    end
  end

  @impl true
  def handle_info({:capture_status, status}, socket) do
    {:noreply,
     socket
     |> assign(:capture, status)
     |> maybe_warn_disk(status)}
  end

  def handle_info({:new_photo, _photo}, socket) do
    socket = load_photos(socket)
    last = max(length(socket.assigns.photos) - 1, 0)
    # follow == (idx == last): ao vivo acompanha; fora do ultimo fica parado
    idx = if socket.assigns.follow, do: last, else: socket.assigns.idx
    {:noreply, navigate(socket, idx)}
  end

  def handle_info({:label_changed, _photo_id}, socket) do
    {:noreply, assign(socket, :tallies, Capture.tallies())}
  end

  def handle_info(%{event: "presence_diff"}, socket) do
    {:noreply, assign(socket, :reviewers, Presence.list_reviewers())}
  end

  def handle_info(:session_reset, socket) do
    {:noreply,
     socket
     |> assign(open: false, idx: 0, follow: true, labels: %{})
     |> load_photos()}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  # ── helpers ──────────────────────────────────────────────────────────────────

  defp load_photos(socket) do
    photos = Capture.list_photos()

    socket
    |> assign(:photos, photos)
    |> assign(:total, length(photos))
    |> assign(:recent, photos |> Enum.reverse() |> Enum.take(@recent))
    |> assign(:tallies, Capture.tallies())
  end

  defp current_photo(%{photos: photos, idx: idx}), do: Enum.at(photos, idx)

  # follow e derivado do indice: estar na ultima foto e estar ao vivo
  defp navigate(socket, idx) do
    last = max(length(socket.assigns.photos) - 1, 0)
    idx = idx |> max(0) |> min(last)
    assign(socket, idx: idx, follow: idx == last)
  end

  defp review_url do
    "http://#{lan_ip()}:#{http_port()}/"
  end

  defp http_port do
    :revela
    |> Application.get_env(RevelaWeb.Endpoint, [])
    |> get_in([:http, :port]) || 4000
  end

  # Endereco IPv4 acessivel pelos celulares na LAN. Pode ser fixado via a env
  # TETHER_LAN_IP; senao, escolhe entre as interfaces ignorando loopback,
  # link-local, CGNAT/Tailscale, docker/bridges e VPNs, preferindo 192.168/10/172.
  defp lan_ip do
    System.get_env("TETHER_LAN_IP") || detect_lan_ip() || "localhost"
  end

  defp detect_lan_ip do
    {:ok, ifs} = :inet.getifaddrs()

    ifs
    |> Enum.reject(fn {name, _opts} -> skip_iface?(to_string(name)) end)
    |> Enum.flat_map(fn {_name, opts} -> Keyword.get_values(opts, :addr) end)
    |> Enum.filter(&usable_ipv4?/1)
    |> Enum.sort_by(&ipv4_rank/1)
    |> List.first()
    |> case do
      {a, b, c, d} -> "#{a}.#{b}.#{c}.#{d}"
      _ -> nil
    end
  end

  defp skip_iface?(name) do
    String.starts_with?(name, ~w(lo docker br- veth virbr tailscale tun wg zt))
  end

  defp usable_ipv4?({127, _, _, _}), do: false
  defp usable_ipv4?({169, 254, _, _}), do: false
  # 100.64.0.0/10 = CGNAT (Tailscale e afins)
  defp usable_ipv4?({100, b, _, _}) when b in 64..127, do: false
  defp usable_ipv4?({a, _, _, _}) when a in 1..223, do: true
  defp usable_ipv4?(_), do: false

  defp ipv4_rank({192, 168, _, _}), do: 0
  defp ipv4_rank({10, _, _, _}), do: 1
  defp ipv4_rank({172, b, _, _}) when b in 16..31, do: 2
  defp ipv4_rank(_), do: 3

  defp qr_svg(url), do: RevelaWeb.QR.svg(url, class: "block h-full w-full")

  # ── render ───────────────────────────────────────────────────────────────────

  @impl true
  def render(assigns) do
    ~H"""
    <div class="min-h-dvh bg-base-200 p-4 sm:p-6 relative overflow-hidden">
      <%!-- Marca d'agua repetida no fundo. O corpo e fixo em vh (acompanha so a
           escala vertical, nunca encolhe com a largura) e as colunas tilam a
           largura exata via auto-fill: entram e saem colunas inteiras conforme
           a janela muda, entao nada fica cortado na borda nem espremido.
           Sobra sao linhas implicitas de altura 0, recortadas pela celula. --%>
      <div
        aria-hidden="true"
        class="absolute inset-0 pointer-events-none select-none overflow-hidden grid grid-cols-[repeat(auto-fill,minmax(34vh,1fr))] grid-rows-[100%] [grid-auto-rows:0]"
      >
        <div :for={_ <- 1..16} class="relative overflow-hidden">
          <span class="absolute top-1/2 left-1/2 -translate-x-1/2 -translate-y-1/2 rotate-[270deg] whitespace-nowrap font-serif italic lowercase leading-none tracking-tight text-[30vh] text-base-content/[0.06]">revela</span>
        </div>
      </div>

      <div class="max-w-5xl mx-auto relative">
        <div class="grid gap-6 lg:grid-cols-3">
          <div class="lg:col-span-1 flex flex-col gap-4">
            <div :if={@notice} class="alert alert-info text-xs py-2 break-all">{@notice}</div>

            <div class="card bg-base-100 shadow">
              <div class="card-body gap-2">
                <h2 class="card-title text-base">Editorial</h2>

                <form :if={!@capture.editorial} phx-submit="start_editorial" class="flex gap-2">
                  <input
                    name="name"
                    placeholder="Nome do editorial"
                    autocomplete="off"
                    class="input input-bordered input-sm flex-1"
                    required
                  />
                  <button type="submit" class="btn btn-primary btn-sm">Iniciar</button>
                </form>

                <div :if={@capture.editorial} class="flex items-center justify-between gap-2">
                  <span class="font-medium truncate">{@capture.editorial}</span>
                  <button
                    phx-click="finish_editorial"
                    data-confirm="Finalizar o editorial limpa a tela de revisao. Os originais e as classificacoes ficam salvos no banco. Continuar?"
                    class="btn btn-outline btn-sm"
                  >
                    Finalizar editorial
                  </button>
                </div>
              </div>
            </div>

            <div class="card bg-base-100 shadow">
              <div class="card-body items-center text-center gap-2">
                <h2 class="card-title">Entrar no estudio</h2>
                <%!-- placa sempre clara com modulos escuros: a leitura nao depende do tema.
                   A zona de silencio ja vem dentro do SVG, entao o padding e minimo. --%>
                <div class="rounded-2xl bg-white p-1.5 ring-1 ring-base-300">
                  <div class="size-48 text-neutral-900">{Phoenix.HTML.raw(@qr)}</div>
                </div>
                <a href={@url} class="link link-primary text-sm font-mono break-all">{@url}</a>
                <p class="text-xs opacity-60">
                  Mesma rede Wi-Fi. Aponte a camera do celular para o QR.
                </p>
              </div>
            </div>

            <.capture_card capture={@capture} />

            <div class="card bg-base-100 shadow">
              <div class="card-body gap-2">
                <h2 class="card-title text-base">
                  No estudio ({length(@reviewers)})
                </h2>
                <div class="flex flex-wrap gap-1">
                  <span :for={r <- @reviewers} class="badge badge-neutral">{r.name}</span>
                  <span :if={@reviewers == []} class="text-xs opacity-50">ninguem conectado</span>
                </div>
              </div>
            </div>
          </div>

          <div class="lg:col-span-2 card bg-base-100 shadow">
            <div class="card-body gap-4">
              <div class="flex items-center justify-between">
                <h2 class="card-title">Fotos ({@total})</h2>
                <div class="flex gap-2 items-center text-xs opacity-70">
                  <span :for={c <- Colors.all()} class="flex items-center gap-1">
                    <span class="h-3 w-3 rounded-full" style={"background-color: #{c.hex}"} />
                  </span>
                </div>
              </div>

              <div :if={@recent == []} class="text-center opacity-50 py-16">
                Nenhuma foto ainda.
              </div>

              <div class="grid grid-cols-2 sm:grid-cols-3 md:grid-cols-4 gap-3">
                <div
                  :for={photo <- @recent}
                  class="relative cursor-pointer"
                  phx-click="open"
                  phx-value-id={photo.id}
                >
                  <img src={photo.web_path} class="w-full aspect-[3/2] object-cover rounded-lg" />
                  <div class="absolute bottom-1 left-1 right-1 flex gap-1 flex-wrap">
                    <span
                      :for={{color, count} <- Map.get(@tallies, photo.id, %{}) |> Enum.sort()}
                      class="text-[10px] font-bold text-white rounded px-1 leading-4"
                      style={"background-color: #{Colors.hex(color)}"}
                    >
                      {count}
                    </span>
                  </div>
                </div>
              </div>
            </div>
          </div>
        </div>
      </div>

      <ViewerComponents.viewer
        :if={@open}
        photo={current_photo(assigns)}
        count={length(@photos)}
        idx={@idx}
        follow={@follow}
        labels={@labels}
        title="host"
        closable={true}
        zoom_id="zoomer-host"
        fs_id="fs-host"
      />
    </div>
    """
  end

  attr :capture, :map, required: true

  def capture_card(assigns) do
    {action_label, action_event, action_disabled?, action_class} =
      capture_action(assigns.capture)

    assigns =
      assign(assigns,
        action_label: action_label,
        action_event: action_event,
        action_disabled?: action_disabled?,
        action_class: action_class,
        help: capture_help(assigns.capture),
        help_class: capture_help_class(assigns.capture),
        disk_hint: free_space_hint(assigns.capture)
      )

    ~H"""
    <div id="capture-card" class="card bg-base-100 shadow">
      <div class="card-body gap-3">
        <div class="flex items-center justify-between gap-3">
          <h2 class="card-title text-base">Captura</h2>
          <.status_badge capture={@capture} />
        </div>

        <button
          id="capture-action"
          type="button"
          phx-click={@action_event}
          disabled={@action_disabled?}
          class={[
            "btn btn-sm w-full transition-colors duration-200",
            @action_class
          ]}
        >
          {@action_label}
        </button>

        <p
          id="capture-help"
          class={["min-h-8 text-xs leading-relaxed", @help_class]}
          aria-live="polite"
        >
          {@help}
        </p>

        <p :if={@disk_hint} id="capture-disk-hint" class="text-xs opacity-50">
          {@disk_hint}
        </p>
      </div>
    </div>
    """
  end

  defp capture_action(%{status: :running}),
    do: {"Desvincular câmera", "stop", false, "btn-outline"}

  defp capture_action(%{status: status}) when status in [:reconnecting, :waiting_camera],
    do: {"Cancelar reconexão", "stop", false, "btn-outline"}

  defp capture_action(%{camera_present: true}),
    do: {"Vincular câmera", "start", false, "btn-primary"}

  defp capture_action(_capture),
    do: {"Conecte a câmera", nil, true, "btn-primary"}

  defp capture_help(%{status: :running}),
    do: "Câmera vinculada. Aguardando disparos."

  defp capture_help(%{status: :waiting_camera}),
    do: "A câmera foi desconectada. Reconecte o cabo USB para retomar automaticamente."

  defp capture_help(%{status: :reconnecting, message: message}) when is_binary(message),
    do: message

  defp capture_help(%{status: :error, message: message}) when is_binary(message),
    do: message

  defp capture_help(%{status: :disk_full, message: message}) when is_binary(message),
    do: message

  defp capture_help(%{camera_present: true}),
    do: "Câmera detectada via USB e pronta para vincular."

  defp capture_help(_capture),
    do: "Ligue a câmera e conecte o cabo USB."

  defp capture_help_class(%{status: status}) when status in [:error, :disk_full],
    do: "text-error"

  defp capture_help_class(%{status: status})
       when status in [:reconnecting, :waiting_camera],
       do: "text-warning"

  defp capture_help_class(_capture), do: "opacity-60"

  # traduz espaco livre para o que o fotografo entende: quantas fotos ainda
  # cabem, calculado a partir da media real de bytes por disparo do editorial.
  # Sem os_mon (:disk_awareness :unavailable) nao polui a UI — o aviso vai ao
  # console do browser via push_event "disk-awareness" (ver maybe_warn_disk/1).
  defp free_space_hint(%{estimated_shots_left: n}) when is_integer(n),
    do: "Espaço livre: cabem ~#{n} fotos."

  defp free_space_hint(_capture), do: nil

  # aviso de os_mon ausente so no DevTools (uma vez por conexao LiveView)
  defp maybe_warn_disk(socket, %{disk_awareness: :unavailable}) do
    if connected?(socket) and not socket.assigns[:disk_warn_pushed] do
      socket
      |> assign(:disk_warn_pushed, true)
      |> push_event("disk-awareness", %{
        message:
          "monitoramento de disco indisponível (pacote erlang-os_mon); parada preventiva desativada"
      })
    else
      socket
    end
  end

  defp maybe_warn_disk(socket, _capture), do: socket

  defp status_badge(assigns) do
    {label, class} =
      case assigns.capture do
        %{status: :running} -> {"vinculada", "badge-success"}
        %{status: :reconnecting} -> {"reconectando", "badge-warning"}
        %{status: :waiting_camera} -> {"desconectada", "badge-warning"}
        %{status: :error} -> {"erro", "badge-error"}
        %{status: :disk_full} -> {"espaço cheio", "badge-error"}
        %{camera_present: true} -> {"detectada", "badge-info"}
        _capture -> {"desconectada", "badge-ghost"}
      end

    assigns = assign(assigns, label: label, class: class)

    ~H"""
    <span id="capture-status" class={["badge", @class]}>{@label}</span>
    """
  end
end
