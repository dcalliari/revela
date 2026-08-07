defmodule RevelaWeb.HostLive do
  @moduledoc """
  Tela de controle no laptop: QR code + URL da LAN para os celulares entrarem,
  status honesto do tether (auto-arm pendente, armado automaticamente,
  retomar apos stop, ingestao degradada), estimativa de fotos restantes no
  disco, quem esta online e a agregacao de cores (consenso) de cada foto entre
  todos os revisores. Sem `:os_mon`, a estimativa de fotos nao aparece e o
  help pede vinculo manual quando ha camera; o console do browser tambem
  recebe um aviso via `push_event("disk-awareness", ...)`.

  **Importar do cartao** (`#card-import`): pasta sob raizes allowlisted
  (`:card_import_allowed_roots` / `REVELA_CARD_IMPORT_ROOTS`; padrao
  `/run/media` e `/media`) via `Capture.import_from_folder/1`. Exige editorial
  ativo; contrato e limites em `Revela.Capture.CardImport` e no README.

  A grade do editorial e paginada (24/pagina, prev/next) e filtravel por
  bolinhas de cor (multi-select; vazio = todas; mudar filtro volta a pagina 1).
  Listagem e contagem vao ao banco via `Capture.list_photos/1` e
  `count_photos/1`; a pagina corrente e um LiveView stream (`:grid_photos`).
  O viewer imersivo continua com a lista completa (`list_photos/0`) para
  idx/follow — nao reusar a pagina da grade. Fotos sem `web_path` (RAW
  importado sem preview) renderizam placeholder, nao quebram a grade.

  No viewer imersivo, `follow` segue a mesma invariante que em `ReviewLive`
  (`follow == (idx == last)`); tecla `L`/`l` chama `go_live`. Demais atalhos
  (cores, setas, limpar) sao tratados aqui via `handle_event("key", ...)`;
  `ViewerComponents` nao exibe legenda ou numeros visiveis — so `aria-label`
  por botao.

  Com `REVELA_DEMO=1`, o Host mostra badge DEMO e, com a captura armada,
  **Disparar (demo)** (caminho real de ingest via arquivo). A tecla `D`/`d`
  só liga com editorial ativo; antes disso use o botão `#demo-fire`.
  """
  use RevelaWeb, :live_view

  alias Revela.Capture
  alias Revela.Capture.CameraServer
  alias RevelaWeb.{Colors, Presence, ViewerComponents}

  # tamanho da pagina da grade; a navegacao do viewer usa a lista completa
  @page_size 24

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

    capture = CameraServer.status()

    socket =
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
      |> assign(:import_path, "")
      |> assign(:labels, Capture.labels_for_reviewer(@host_id))
      |> assign(:page, 0)
      |> assign(:page_size, @page_size)
      |> assign(:filter_colors, MapSet.new())
      |> stream_configure(:grid_photos, dom_id: &"grid-photo-#{&1.id}")
      |> load_photos()
      |> maybe_warn_disk(capture)

    socket = if connected?(socket), do: broadcast_host_viewer(socket), else: socket

    {:ok, socket}
  end

  @impl true
  def handle_event("start", _params, socket) do
    {:noreply, assign(socket, :capture, CameraServer.start_capture())}
  end

  def handle_event("stop", _params, socket) do
    {:noreply, assign(socket, :capture, CameraServer.stop_capture())}
  end

  def handle_event("demo_fire", _params, socket) do
    case CameraServer.demo_fire() do
      {:ok, _path} ->
        {:noreply, socket}

      {:error, reason} when reason in [:not_armed, :not_demo] ->
        {:noreply, socket}

      {:error, reason} ->
        {:noreply, assign(socket, :notice, "Falha ao gravar JPEG de demo (#{inspect(reason)}).")}
    end
  end

  # ── visualizador em tela cheia (host classifica como "host") ─────────────────

  def handle_event("open", %{"id" => id}, socket) do
    id = String.to_integer(id)
    last = max(length(socket.assigns.photos) - 1, 0)
    idx = Enum.find_index(socket.assigns.photos, &(&1.id == id)) || last
    {:noreply, socket |> assign(:open, true) |> navigate(idx)}
  end

  def handle_event("close", _params, socket) do
    {:noreply, socket |> assign(open: false) |> broadcast_host_viewer()}
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
         |> assign(:page, 0)
         |> assign(:filter_colors, MapSet.new())
         |> assign(:notice, "Editorial \"#{name}\" iniciado. Originais em: #{folder}")
         |> load_photos()
         |> broadcast_host_viewer()}
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
     |> assign(:page, 0)
     |> assign(:filter_colors, MapSet.new())
     |> assign(:notice, "Editorial finalizado. Os originais ficam salvos na pasta.")
     |> load_photos()
     |> broadcast_host_viewer()}
  end

  def handle_event("toggle_color_filter", %{"color" => color}, socket) do
    color = String.to_integer(color)

    filter_colors =
      if MapSet.member?(socket.assigns.filter_colors, color) do
        MapSet.delete(socket.assigns.filter_colors, color)
      else
        MapSet.put(socket.assigns.filter_colors, color)
      end

    {:noreply,
     socket
     |> assign(:filter_colors, filter_colors)
     |> assign(:page, 0)
     |> load_grid()}
  end

  def handle_event("grid_prev_page", _params, socket) do
    page = max(socket.assigns.page - 1, 0)
    {:noreply, socket |> assign(:page, page) |> load_grid()}
  end

  def handle_event("grid_next_page", _params, socket) do
    last_page = max(socket.assigns.total_pages - 1, 0)
    page = min(socket.assigns.page + 1, last_page)
    {:noreply, socket |> assign(:page, page) |> load_grid()}
  end

  # importa pasta do cartao (JPEG/RAW) para o editorial ativo; recusa sem editorial
  def handle_event("import_card", %{"path" => path}, socket) do
    path = String.trim(path)

    socket = assign(socket, :import_path, path)

    cond do
      path == "" ->
        {:noreply, assign(socket, :notice, "Informe o caminho da pasta do cartão.")}

      not allowed_import_path?(path) ->
        {:noreply,
         assign(
           socket,
           :notice,
           "Pasta fora das raízes de mídia permitidas (ex.: /run/media, /media)."
         )}

      true ->
        case Capture.import_from_folder(path) do
          {:ok, %{imported: imported, skipped: skipped, errors: errors}} ->
            notice =
              cond do
                errors != [] ->
                  "Importação parcial: #{imported} novas, #{skipped} já existentes, " <>
                    "#{length(errors)} com erro."

                imported == 0 and skipped > 0 ->
                  "Nenhuma foto nova (#{skipped} já estavam no editorial)."

                imported == 0 ->
                  "Nenhum JPEG/RAW suportado na pasta."

                true ->
                  "Importadas #{imported} foto(s)" <>
                    if(skipped > 0, do: " (#{skipped} já existentes).", else: ".")
              end

            socket =
              socket
              |> assign(:notice, notice)
              |> load_photos()

            last = max(length(socket.assigns.photos) - 1, 0)
            idx = if socket.assigns.follow, do: last, else: socket.assigns.idx
            {:noreply, navigate(socket, idx)}

          {:error, :no_active_editorial} ->
            {:noreply,
             assign(socket, :notice, "Abra um editorial antes de importar fotos do cartão.")}

          {:error, :not_a_directory} ->
            {:noreply, assign(socket, :notice, "Pasta não encontrada: #{path}")}

          {:error, :empty_path} ->
            {:noreply, assign(socket, :notice, "Informe o caminho da pasta do cartão.")}

          {:error, {:source_directory, reason}} ->
            {:noreply,
             assign(socket, :notice, "Não foi possível ler a pasta do cartão: #{inspect(reason)}")}
        end
    end
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

  # Page-level D only (classification stays on the open viewer). Bound only when
  # demo is armed and an editorial is active — window keyups still fire while
  # the name <input> is focused, so keep the binding off while that form shows.
  # Pre-editorial shots use #demo-fire.
  def handle_event("demo_key", %{"key" => key}, socket) when key in ["d", "D"] do
    if demo_window_key?(socket.assigns.capture) do
      handle_event("demo_fire", %{}, socket)
    else
      {:noreply, socket}
    end
  end

  def handle_event("demo_key", _params, socket), do: {:noreply, socket}

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

  def handle_info({:label_changed, photo_id}, socket) do
    {:noreply, refresh_grid_for_label(socket, photo_id)}
  end

  def handle_info(%{event: "presence_diff"}, socket) do
    {:noreply, assign(socket, :reviewers, Presence.list_reviewers())}
  end

  def handle_info(:session_reset, socket) do
    {:noreply,
     socket
     |> assign(
       open: false,
       idx: 0,
       follow: true,
       labels: %{},
       page: 0,
       filter_colors: MapSet.new()
     )
     |> load_photos()
     |> broadcast_host_viewer()}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  # ── helpers ──────────────────────────────────────────────────────────────────

  # Host so importa de raizes de midia removivel (padrao /run/media e /media;
  # override via config :card_import_allowed_roots / REVELA_CARD_IMPORT_ROOTS).
  # Resolve symlinks before the prefix check so a path under an allowed root
  # that links outside those roots is refused.
  defp allowed_import_path?(path) when is_binary(path) do
    case resolve_real_path(path) do
      {:ok, real} -> under_allowed_import_root?(real)
      {:error, _} -> false
    end
  end

  defp under_allowed_import_root?(real_path) do
    :revela
    |> Application.get_env(:card_import_allowed_roots, ["/run/media", "/media"])
    |> List.wrap()
    |> Enum.any?(fn root ->
      root_path =
        case resolve_real_path(to_string(root)) do
          {:ok, resolved} -> resolved
          {:error, _} -> Path.expand(to_string(root))
        end

      real_path == root_path or String.starts_with?(real_path, root_path <> "/")
    end)
  end

  defp resolve_real_path(path) when is_binary(path) do
    abs = Path.expand(path)
    resolve_real_path_components(Path.split(abs), [], MapSet.new())
  end

  defp resolve_real_path_components([], acc, _seen) do
    {:ok, Path.join(Enum.reverse(acc))}
  end

  defp resolve_real_path_components([comp | rest], [], seen) do
    resolve_real_path_components(rest, [comp], seen)
  end

  defp resolve_real_path_components([comp | rest], acc, seen) do
    current = Path.join(Enum.reverse([comp | acc]))

    if MapSet.member?(seen, current) do
      {:error, :symlink_loop}
    else
      case File.lstat(current) do
        {:ok, %{type: :symlink}} ->
          case File.read_link(current) do
            {:ok, target} ->
              parent = Path.join(Enum.reverse(acc))

              resolved =
                if Path.type(target) == :absolute do
                  Path.expand(target)
                else
                  Path.expand(target, parent)
                end

              resolve_real_path_components(
                Path.split(resolved) ++ rest,
                [],
                MapSet.put(seen, current)
              )

            {:error, reason} ->
              {:error, reason}
          end

        {:ok, _} ->
          resolve_real_path_components(rest, [comp | acc], seen)

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  # lista completa para o viewer (follow/atalhos); grade usa pagina filtrada via stream
  defp load_photos(socket) do
    photos = Capture.list_photos()

    socket
    |> assign(:photos, photos)
    |> load_grid()
  end

  defp load_grid(socket) do
    colors = MapSet.to_list(socket.assigns.filter_colors)
    filter_opts = [colors: colors]
    total = Capture.count_photos(filter_opts)
    page_size = socket.assigns.page_size
    total_pages = max(ceil(total / page_size), 1)
    page = socket.assigns.page |> max(0) |> min(total_pages - 1)
    offset = page * page_size

    grid_photos =
      Capture.list_photos(
        Keyword.merge(filter_opts, order: :desc, limit: page_size, offset: offset)
      )

    socket
    |> assign(:page, page)
    |> assign(:total, total)
    |> assign(:total_pages, total_pages)
    |> assign(:grid_empty?, grid_photos == [])
    |> assign(:grid_photo_ids, MapSet.new(Enum.map(grid_photos, & &1.id)))
    |> assign(:tallies, Capture.tallies())
    |> stream(:grid_photos, grid_photos, reset: true)
  end

  defp refresh_grid_for_label(socket, photo_id) do
    if MapSet.size(socket.assigns.filter_colors) > 0 do
      load_grid(socket)
    else
      socket
      |> assign(:tallies, Capture.tallies())
      |> maybe_restream_grid_photo(photo_id)
    end
  end

  defp maybe_restream_grid_photo(socket, photo_id) do
    if MapSet.member?(socket.assigns.grid_photo_ids, photo_id) do
      stream_insert(socket, :grid_photos, Capture.get_photo!(photo_id))
    else
      socket
    end
  end

  defp broadcast_host_viewer(socket) do
    photo = current_photo(socket.assigns)

    Capture.broadcast_host_viewer(%{
      photo_id: photo && photo.id,
      follow: socket.assigns.follow,
      open: socket.assigns.open
    })

    socket
  end

  defp current_photo(%{photos: photos, idx: idx}), do: Enum.at(photos, idx)

  # follow e derivado do indice: estar na ultima foto e estar ao vivo
  defp navigate(socket, idx) do
    last = max(length(socket.assigns.photos) - 1, 0)
    idx = idx |> max(0) |> min(last)

    socket
    |> assign(idx: idx, follow: idx == last)
    |> broadcast_host_viewer()
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
    <div
      class="min-h-dvh bg-base-200 p-4 sm:p-6 relative overflow-hidden"
      phx-window-keyup={demo_window_key?(@capture) && "demo_key"}
      phx-key={demo_window_key?(@capture) && "d"}
    >
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
        <div
          :if={Map.get(@capture, :demo) == true}
          id="demo-badge"
          class="mb-4 flex items-center gap-2 rounded-lg border border-warning/40 bg-warning/15 px-3 py-2 text-sm font-semibold tracking-wide text-warning"
          role="status"
        >
          <span class="badge badge-warning badge-sm font-bold">DEMO</span>
          <span class="font-normal opacity-80">
            Modo demo (`REVELA_DEMO`) — sem câmera física; `D` dispara JPEG sintético.
          </span>
        </div>

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

            <div id="card-import" class="card bg-base-100 shadow">
              <div class="card-body gap-2">
                <h2 class="card-title text-base">Importar do cartão</h2>
                <p class="text-xs opacity-60 leading-relaxed">
                  Quando a captura tethered cair, copie a pasta do microSD e importe
                  JPEG/RAW (.jpg/.jpeg/.cr2/.cr3) para o editorial aberto.
                </p>
                <form id="card-import-form" phx-submit="import_card" class="flex flex-col gap-2">
                  <input
                    id="card-import-path"
                    name="path"
                    value={@import_path}
                    placeholder="/caminho/para/DCIM/..."
                    autocomplete="off"
                    class="input input-bordered input-sm w-full font-mono text-xs"
                  />
                  <button
                    id="card-import-submit"
                    type="submit"
                    disabled={!@capture.editorial}
                    class="btn btn-secondary btn-sm"
                  >
                    Importar pasta
                  </button>
                </form>
                <p :if={!@capture.editorial} id="card-import-hint" class="text-xs text-warning">
                  Inicie um editorial para habilitar a importação.
                </p>
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
                <.link
                  id="tv-open-link"
                  navigate={~p"/tv"}
                  target="_blank"
                  class="link link-hover text-xs opacity-70"
                >
                  Abrir modo apresentação (/tv)
                </.link>
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
              <div class="flex items-center justify-between gap-3 flex-wrap">
                <h2 id="host-photos-title" class="card-title">Fotos ({@total})</h2>
                <div
                  id="color-filters"
                  class="flex gap-2 items-center text-xs"
                  role="group"
                  aria-label="Filtrar por cor"
                >
                  <button
                    :for={c <- Colors.all()}
                    type="button"
                    id={"color-filter-#{c.value}"}
                    phx-click="toggle_color_filter"
                    phx-value-color={c.value}
                    aria-pressed={to_string(MapSet.member?(@filter_colors, c.value))}
                    title={"Filtrar #{c.name}"}
                    class={[
                      "h-4 w-4 rounded-full transition ring-offset-2 ring-offset-base-100",
                      MapSet.member?(@filter_colors, c.value) && "ring-2 ring-base-content scale-110",
                      !MapSet.member?(@filter_colors, c.value) && "opacity-70 hover:opacity-100"
                    ]}
                    style={"background-color: #{c.hex}"}
                  />
                </div>
              </div>

              <div
                :if={@grid_empty?}
                id="host-grid-empty"
                class="text-center opacity-50 py-16"
              >
                <%= if MapSet.size(@filter_colors) > 0 do %>
                  Nenhuma foto com essas cores.
                <% else %>
                  Nenhuma foto ainda.
                <% end %>
              </div>

              <div
                id="host-grid"
                phx-update="stream"
                class="grid grid-cols-2 sm:grid-cols-3 md:grid-cols-4 gap-3"
              >
                <div
                  :for={{dom_id, photo} <- @streams.grid_photos}
                  id={dom_id}
                  class="relative cursor-pointer"
                  phx-click="open"
                  phx-value-id={photo.id}
                >
                  <%= if photo.web_path do %>
                    <img src={photo.web_path} class="w-full aspect-[3/2] object-cover rounded-lg" />
                  <% else %>
                    <div class="w-full aspect-[3/2] rounded-lg bg-slate-900 flex items-center justify-center text-xs text-slate-400">
                      RAW sem preview
                    </div>
                  <% end %>
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

              <div
                :if={@total_pages > 1}
                id="host-grid-pagination"
                class="flex items-center justify-between gap-3 pt-1"
              >
                <button
                  id="grid-prev-page"
                  type="button"
                  phx-click="grid_prev_page"
                  disabled={@page <= 0}
                  class="btn btn-sm btn-outline"
                >
                  Anterior
                </button>
                <span id="grid-page-label" class="text-xs opacity-70">
                  Página {@page + 1} de {@total_pages}
                </span>
                <button
                  id="grid-next-page"
                  type="button"
                  phx-click="grid_next_page"
                  disabled={@page >= @total_pages - 1}
                  class="btn btn-sm btn-outline"
                >
                  Próxima
                </button>
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

    demo_armed? =
      Map.get(assigns.capture, :demo) == true and assigns.capture.status == :running

    assigns =
      assign(assigns,
        action_label: action_label,
        action_event: action_event,
        action_disabled?: action_disabled?,
        action_class: action_class,
        help: capture_help(assigns.capture),
        help_class: capture_help_class(assigns.capture),
        disk_hint: free_space_hint(assigns.capture),
        demo_armed?: demo_armed?
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

        <button
          :if={@demo_armed?}
          id="demo-fire"
          type="button"
          phx-click="demo_fire"
          class="btn btn-secondary btn-sm w-full"
        >
          Disparar (demo)
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

  defp capture_action(%{auto_arm_pending: true}),
    do: {"Armando tether…", nil, true, "btn-primary"}

  defp capture_action(%{operator_stopped: true, camera_present: true}),
    do: {"Retomar captura", "start", false, "btn-primary"}

  defp capture_action(%{camera_present: true}),
    do: {"Vincular câmera", "start", false, "btn-primary"}

  defp capture_action(_capture),
    do: {"Conecte a câmera", nil, true, "btn-primary"}

  defp capture_help(%{auto_arm_pending: true}),
    do: "Câmera detectada; armando tether automaticamente…"

  defp capture_help(%{status: :running, ingest_awareness: :unavailable}),
    do:
      "Tether armado, mas ingestão por pasta indisponível (inotify). " <>
        "Fotos não entram na revisão automaticamente."

  defp capture_help(%{status: :running, demo: true, editorial: name})
       when is_binary(name) and name != "",
       do: "Demo armada. Dispare com o botão ou a tecla D."

  defp capture_help(%{status: :running, demo: true}),
    do: "Demo armada. Dispare com o botão."

  defp capture_help(%{status: :running, armed_automatically: true}),
    do: "Câmera vinculada automaticamente. Aguardando disparos."

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

  defp capture_help(%{operator_stopped: true, camera_present: true}),
    do: "Captura pausada. Clique para retomar o tether."

  defp capture_help(%{camera_present: true, editorial: nil}),
    do: "Câmera detectada. Inicie um editorial para armar o tether automaticamente."

  defp capture_help(%{camera_present: true, disk_awareness: :unavailable}),
    do: "Câmera detectada. Vincule manualmente — monitoramento de disco indisponível."

  defp capture_help(%{camera_present: true}),
    do: "Câmera detectada; o tether arma automaticamente quando o disco estiver OK."

  defp capture_help(_capture),
    do: "Ligue a câmera e conecte o cabo USB."

  # Window D only when demo is armed and the editorial name form is gone.
  defp demo_window_key?(%{demo: true, status: :running, editorial: name})
       when is_binary(name) and name != "",
       do: true

  defp demo_window_key?(_capture), do: false

  defp capture_help_class(%{auto_arm_pending: true}), do: "opacity-60"

  defp capture_help_class(%{status: :running, ingest_awareness: :unavailable}),
    do: "text-warning"

  defp capture_help_class(%{status: status}) when status in [:error, :disk_full],
    do: "text-error"

  defp capture_help_class(%{status: status})
       when status in [:reconnecting, :waiting_camera],
       do: "text-warning"

  defp capture_help_class(_capture), do: "opacity-60"

  # traduz espaco livre para o que o fotografo entende: quantas fotos ainda
  # cabem, calculado a partir da media real de bytes por disparo do editorial.
  # Sem os_mon (:disk_awareness :unavailable) esta dica some; o aviso de
  # monitoramento vai ao help (camera presente) e ao console via push_event
  # "disk-awareness" (ver maybe_warn_disk/1).
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
        %{auto_arm_pending: true} -> {"armando", "badge-info"}
        %{status: :running, ingest_awareness: :unavailable} -> {"sem ingestão", "badge-warning"}
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
