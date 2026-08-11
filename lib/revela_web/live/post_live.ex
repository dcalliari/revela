defmodule RevelaWeb.PostLive do
  @moduledoc """
  Tela de pos-producao: navega o editorial completo (nao so as 24 recentes),
  filtra por cor, seleciona intervalo contiguo (clique + shift-clique), aplica
  classificacao na selecao, gera URL de previews para a marca e baixa RAW da
  selecao. Desfazer: botao fixo + Ctrl/Cmd+Z + historico visivel da sessao.
  """
  use RevelaWeb, :live_view

  alias Revela.Capture
  alias Revela.Delivery
  alias RevelaWeb.{Colors, RawDownloadController}

  @host_id "host"
  @host_name "host"
  @history_limit 40

  @impl true
  def mount(params, _session, socket) do
    if connected?(socket) do
      Capture.subscribe_photos()
      Capture.subscribe_labels()
    end

    editorials = Capture.list_editorials()

    socket =
      socket
      |> assign(:editorials, editorials)
      |> assign(:editorial, nil)
      |> assign(:photos, [])
      |> assign(:labels, %{})
      |> assign(:tallies, %{})
      |> assign(:filter, :all)
      |> assign(:selected_ids, MapSet.new())
      |> assign(:anchor_id, nil)
      |> assign(:history, [])
      |> assign(:share_url, nil)
      |> assign(:share_error, nil)
      |> assign(:raw_error, nil)
      |> assign(:raw_href, nil)
      |> assign(:page_title, "Pos-producao")

    socket =
      case params do
        %{"editorial_id" => _} ->
          socket

        _ ->
          case editorials do
            [first | _] -> push_navigate(socket, to: ~p"/post/#{first.id}")
            [] -> socket
          end
      end

    {:ok, socket}
  end

  @impl true
  def handle_params(%{"editorial_id" => id}, _uri, socket) do
    {:noreply, load_editorial(socket, id)}
  end

  def handle_params(_params, _uri, socket), do: {:noreply, socket}

  @impl true
  def handle_event("select_editorial", %{"id" => id}, socket) do
    {:noreply, push_patch(socket, to: ~p"/post/#{id}")}
  end

  def handle_event("filter", %{"color" => "all"}, socket) do
    {:noreply, assign(socket, filter: :all, selected_ids: MapSet.new(), anchor_id: nil)}
  end

  def handle_event("filter", %{"color" => "none"}, socket) do
    {:noreply, assign(socket, filter: :none, selected_ids: MapSet.new(), anchor_id: nil)}
  end

  def handle_event("filter", %{"color" => color}, socket) do
    {:noreply,
     assign(socket,
       filter: String.to_integer(color),
       selected_ids: MapSet.new(),
       anchor_id: nil
     )}
  end

  def handle_event("select_photo", %{"id" => id} = params, socket) do
    photo_id = String.to_integer(id)
    shift? = params["shift"] in [true, "true"]

    visible = visible_photos(socket.assigns)
    ids = Enum.map(visible, & &1.id)

    unless photo_id in ids do
      {:noreply, socket}
    else
      {selected, anchor} =
        if shift? and socket.assigns.anchor_id do
          from_idx = Enum.find_index(ids, &(&1 == socket.assigns.anchor_id)) || 0
          to_idx = Enum.find_index(ids, &(&1 == photo_id)) || 0
          {lo, hi} = if from_idx <= to_idx, do: {from_idx, to_idx}, else: {to_idx, from_idx}
          range = ids |> Enum.slice(lo..hi) |> MapSet.new()
          {range, socket.assigns.anchor_id}
        else
          {MapSet.new([photo_id]), photo_id}
        end

      {:noreply, assign(socket, selected_ids: selected, anchor_id: anchor, raw_error: nil)}
    end
  end

  def handle_event("clear_selection", _params, socket) do
    {:noreply, assign(socket, selected_ids: MapSet.new(), anchor_id: nil)}
  end

  def handle_event("label_selection", %{"color" => color}, socket) do
    color = String.to_integer(color)
    ids = MapSet.to_list(socket.assigns.selected_ids)

    if ids == [] do
      {:noreply, socket}
    else
      before =
        Map.new(ids, fn id -> {id, Map.get(socket.assigns.labels, id)} end)

      Enum.each(ids, fn id ->
        Capture.set_label(id, @host_id, @host_name, color)
      end)

      labels =
        Enum.reduce(ids, socket.assigns.labels, fn id, acc -> Map.put(acc, id, color) end)

      entry = %{
        id: System.unique_integer([:positive]),
        at: DateTime.utc_now(),
        summary: "Marcou #{length(ids)} foto(s) de #{Colors.name(color)}",
        reverse: Enum.map(before, fn {id, old} -> {:label, id, old} end)
      }

      {:noreply,
       socket
       |> assign(:labels, labels)
       |> assign(:tallies, Capture.tallies_for_editorial(socket.assigns.editorial.id))
       |> push_history(entry)}
    end
  end

  def handle_event("clear_selection_labels", _params, socket) do
    ids = MapSet.to_list(socket.assigns.selected_ids)

    if ids == [] do
      {:noreply, socket}
    else
      before = Map.new(ids, fn id -> {id, Map.get(socket.assigns.labels, id)} end)

      Enum.each(ids, fn id -> Capture.clear_label(id, @host_id) end)

      labels = Enum.reduce(ids, socket.assigns.labels, fn id, acc -> Map.delete(acc, id) end)

      entry = %{
        id: System.unique_integer([:positive]),
        at: DateTime.utc_now(),
        summary: "Limpou cor de #{length(ids)} foto(s)",
        reverse: Enum.map(before, fn {id, old} -> {:label, id, old} end)
      }

      {:noreply,
       socket
       |> assign(:labels, labels)
       |> assign(:tallies, Capture.tallies_for_editorial(socket.assigns.editorial.id))
       |> push_history(entry)}
    end
  end

  def handle_event("undo", _params, socket), do: {:noreply, undo(socket)}

  def handle_event("keydown", %{"key" => key, "ctrlKey" => ctrl, "metaKey" => meta}, socket)
      when key in ["z", "Z"] and (ctrl == true or meta == true) do
    {:noreply, undo(socket)}
  end

  def handle_event("keydown", _params, socket), do: {:noreply, socket}

  def handle_event("share_brand", _params, socket) do
    ids = selected_or_filtered_ids(socket.assigns)

    case Delivery.create_brand_share(socket.assigns.editorial.id, ids,
           label: share_label(socket.assigns)
         ) do
      {:ok, _share, path} ->
        url = RevelaWeb.Lan.absolute_url(path)

        {:noreply,
         socket
         |> assign(:share_url, url)
         |> assign(:share_error, nil)}

      {:error, :empty_selection} ->
        {:noreply,
         assign(socket,
           share_error: "Selecione um intervalo (ou filtre por cor).",
           share_url: nil
         )}

      {:error, reason} ->
        {:noreply,
         assign(socket, share_error: "Falha ao criar link: #{inspect(reason)}", share_url: nil)}
    end
  end

  def handle_event("select_brand_picks", _params, socket) do
    case socket.assigns.editorial do
      nil ->
        {:noreply, socket}

      editorial ->
        ids = Capture.brand_labeled_photo_ids(editorial.id)
        tallies = Capture.tallies_for_editorial(editorial.id)

        if ids == [] do
          {:noreply,
           socket
           |> assign(:tallies, tallies)
           |> assign(:filter, :all)
           |> assign(:selected_ids, MapSet.new())
           |> assign(:anchor_id, nil)
           |> assign(
             :raw_error,
             "A marca ainda nao marcou fotos neste editorial."
           )
           |> assign(:raw_href, nil)}
        else
          {:noreply,
           socket
           |> assign(:tallies, tallies)
           |> assign(:filter, :all)
           |> assign(:selected_ids, MapSet.new(ids))
           |> assign(:anchor_id, List.first(ids))
           |> assign(:raw_error, nil)
           |> assign(:raw_href, nil)}
        end
    end
  end

  def handle_event("prepare_raw", _params, socket) do
    ids = MapSet.to_list(socket.assigns.selected_ids)

    if ids == [] do
      {:noreply,
       assign(socket, raw_error: "Selecione um intervalo para baixar RAW.", raw_href: nil)}
    else
      pull = Delivery.raw_pull(ids)

      if pull.files == [] do
        {:noreply,
         assign(socket,
           raw_error:
             "Nenhum raw_path disponivel nas fotos selecionadas (arquivo ausente ou vazio).",
           raw_href: nil
         )}
      else
        token = RawDownloadController.create_token(socket.assigns.editorial.id, ids)
        href = ~p"/raws/#{token}"

        msg =
          if pull.missing == [] do
            nil
          else
            "#{length(pull.missing)} foto(s) sem RAW serao omitidas; #{length(pull.files)} no zip."
          end

        {:noreply, assign(socket, raw_href: href, raw_error: msg)}
      end
    end
  end

  @impl true
  def handle_info({:new_photo, photo}, socket) do
    case socket.assigns.editorial do
      %{id: id} when photo.editorial_id == id ->
        {:noreply, refresh_editorial_data(socket)}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_info({:label_changed, _photo_id}, socket) do
    {:noreply, refresh_editorial_data(socket)}
  end

  def handle_info(:session_reset, socket) do
    socket = assign(socket, :editorials, Capture.list_editorials())

    case socket.assigns.editorial do
      %{id: id} -> {:noreply, load_editorial(socket, id)}
      nil -> {:noreply, socket}
    end
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  defp load_editorial(socket, id) when is_binary(id) do
    case Integer.parse(id) do
      {int, ""} -> load_editorial(socket, int)
      _ -> clear_editorial(socket)
    end
  end

  defp load_editorial(socket, id) when is_integer(id) do
    case Capture.get_editorial(id) do
      nil ->
        clear_editorial(socket)

      editorial ->
        photos = Capture.list_photos_for_editorial(editorial.id)
        labels = Capture.labels_for_reviewer_in_editorial(@host_id, editorial.id)
        tallies = Capture.tallies_for_editorial(editorial.id)

        socket
        |> assign(:editorial, editorial)
        |> assign(:photos, photos)
        |> assign(:labels, labels)
        |> assign(:tallies, tallies)
        |> assign(:filter, :all)
        |> assign(:history, [])
        |> assign(:selected_ids, MapSet.new())
        |> assign(:anchor_id, nil)
        |> assign(:share_url, nil)
        |> assign(:share_error, nil)
        |> assign(:raw_error, nil)
        |> assign(:raw_href, nil)
        |> assign(:page_title, "Pos · #{editorial.name}")
        |> assign(:editorials, Capture.list_editorials())
    end
  end

  defp refresh_editorial_data(socket) do
    case socket.assigns.editorial do
      nil ->
        socket

      editorial ->
        socket
        |> assign(:photos, Capture.list_photos_for_editorial(editorial.id))
        |> assign(:labels, Capture.labels_for_reviewer_in_editorial(@host_id, editorial.id))
        |> assign(:tallies, Capture.tallies_for_editorial(editorial.id))
    end
  end

  defp clear_editorial(socket) do
    socket
    |> assign(:editorial, nil)
    |> assign(:photos, [])
    |> assign(:labels, %{})
    |> assign(:tallies, %{})
    |> assign(:filter, :all)
    |> assign(:history, [])
    |> assign(:selected_ids, MapSet.new())
    |> assign(:anchor_id, nil)
    |> assign(:share_url, nil)
    |> assign(:share_error, nil)
    |> assign(:raw_error, nil)
    |> assign(:raw_href, nil)
  end

  defp visible_photos(%{photos: photos, labels: labels, filter: filter}) do
    case filter do
      :all ->
        photos

      :none ->
        Enum.filter(photos, fn p -> is_nil(Map.get(labels, p.id)) end)

      color when is_integer(color) ->
        Enum.filter(photos, fn p -> Map.get(labels, p.id) == color end)
    end
  end

  defp selected_or_filtered_ids(assigns) do
    selected = MapSet.to_list(assigns.selected_ids)

    if selected != [] do
      selected
    else
      assigns |> visible_photos() |> Enum.map(& &1.id)
    end
  end

  defp share_label(%{editorial: %{name: name}, filter: filter, selected_ids: selected}) do
    base = name || "editorial"

    cond do
      MapSet.size(selected) > 0 -> "#{base} · #{MapSet.size(selected)} fotos"
      filter == :all -> "#{base} · todas"
      filter == :none -> "#{base} · sem cor"
      is_integer(filter) -> "#{base} · #{Colors.name(filter)}"
      true -> base
    end
  end

  defp push_history(socket, entry) do
    history = [entry | socket.assigns.history] |> Enum.take(@history_limit)
    assign(socket, :history, history)
  end

  defp undo(%{assigns: %{editorial: nil}} = socket), do: socket

  defp undo(socket) do
    case socket.assigns.history do
      [] ->
        socket

      [entry | rest] ->
        labels =
          Enum.reduce(entry.reverse, socket.assigns.labels, fn
            {:label, id, nil}, acc ->
              Capture.clear_label(id, @host_id)
              Map.delete(acc, id)

            {:label, id, color}, acc ->
              Capture.set_label(id, @host_id, @host_name, color)
              Map.put(acc, id, color)
          end)

        socket
        |> assign(:history, rest)
        |> assign(:labels, labels)
        |> assign(:tallies, Capture.tallies_for_editorial(socket.assigns.editorial.id))
    end
  end

  @impl true
  def render(assigns) do
    assigns = assign(assigns, :visible, visible_photos(assigns))

    ~H"""
    <div
      id="post-root"
      class="min-h-dvh bg-base-200"
      phx-window-keydown="keydown"
    >
      <div class="max-w-7xl mx-auto p-4 sm:p-6 flex flex-col gap-4">
        <header class="flex flex-wrap items-end justify-between gap-3">
          <div>
            <p class="font-serif italic text-3xl lowercase tracking-tight text-base-content/80">
              revela
            </p>
            <h1 class="text-xl font-semibold">Pós-produção</h1>
            <p class="text-sm opacity-60">
              Grade completa · intervalo (clique + shift) · marca · RAW
            </p>
          </div>
          <div class="flex flex-wrap gap-2">
            <.link navigate={~p"/host"} class="btn btn-ghost btn-sm">Host ao vivo</.link>
            <button
              id="post-undo"
              type="button"
              phx-click="undo"
              disabled={@history == []}
              class="btn btn-outline btn-sm"
              title="Ctrl+Z / Cmd+Z"
            >
              Desfazer
            </button>
          </div>
        </header>

        <div :if={@editorials == []} class="card bg-base-100 shadow">
          <div class="card-body text-center opacity-60 py-16">
            Nenhum editorial ainda. Inicie um em <a href="/host" class="link">/host</a>.
          </div>
        </div>

        <div :if={@editorials != []} class="grid gap-4 lg:grid-cols-[16rem_1fr]">
          <aside class="card bg-base-100 shadow h-fit">
            <div class="card-body gap-2 p-3">
              <h2 class="card-title text-sm">Editoriais</h2>
              <button
                :for={e <- @editorials}
                type="button"
                id={"editorial-#{e.id}"}
                phx-click="select_editorial"
                phx-value-id={e.id}
                class={[
                  "btn btn-sm justify-start font-normal normal-case",
                  @editorial && @editorial.id == e.id && "btn-primary",
                  !(@editorial && @editorial.id == e.id) && "btn-ghost"
                ]}
              >
                <span class="truncate">{e.name}</span>
                <span :if={is_nil(e.finished_at)} class="badge badge-success badge-xs ml-auto">ativo</span>
              </button>
            </div>
          </aside>

          <section :if={@editorial} class="flex flex-col gap-4">
            <div class="card bg-base-100 shadow">
              <div class="card-body gap-3 p-4">
                <div class="flex flex-wrap items-center justify-between gap-2">
                  <div>
                    <h2 class="card-title text-base">{@editorial.name}</h2>
                    <p class="text-xs opacity-50">
                      {length(@photos)} fotos · {if @editorial.finished_at,
                        do: "finalizado",
                        else: "em captura"}
                    </p>
                  </div>
                  <p class="text-xs opacity-60">
                    Selecionadas:
                    <span id="selection-count" class="font-semibold">{MapSet.size(@selected_ids)}</span>
                    · visíveis: {length(@visible)}
                  </p>
                </div>

                <div id="color-filters" class="flex flex-wrap gap-2 items-center">
                  <button
                    type="button"
                    id="filter-all"
                    phx-click="filter"
                    phx-value-color="all"
                    class={["btn btn-xs", @filter == :all && "btn-active"]}
                  >
                    Todas
                  </button>
                  <button
                    type="button"
                    id="filter-none"
                    phx-click="filter"
                    phx-value-color="none"
                    class={["btn btn-xs", @filter == :none && "btn-active"]}
                  >
                    Sem cor
                  </button>
                  <button
                    :for={c <- Colors.all()}
                    type="button"
                    id={"filter-#{c.value}"}
                    phx-click="filter"
                    phx-value-color={c.value}
                    class={[
                      "btn btn-xs gap-1",
                      @filter == c.value && "btn-active"
                    ]}
                  >
                    <span class="h-2.5 w-2.5 rounded-full" style={"background-color: #{c.hex}"} />
                    {c.name}
                  </button>
                </div>

                <div class="flex flex-wrap gap-2 items-center border-t border-base-300 pt-3">
                  <span class="text-xs opacity-60 mr-1">Na seleção:</span>
                  <button
                    :for={c <- Colors.all()}
                    type="button"
                    id={"label-sel-#{c.value}"}
                    phx-click="label_selection"
                    phx-value-color={c.value}
                    disabled={MapSet.size(@selected_ids) == 0}
                    class="btn btn-xs btn-circle"
                    style={"background-color: #{c.hex}; border-color: #{c.hex}"}
                    aria-label={"Marcar #{c.name}"}
                  />
                  <button
                    type="button"
                    id="clear-sel-labels"
                    phx-click="clear_selection_labels"
                    disabled={MapSet.size(@selected_ids) == 0}
                    class="btn btn-xs"
                  >
                    Limpar cor
                  </button>
                  <button
                    type="button"
                    id="clear-selection"
                    phx-click="clear_selection"
                    disabled={MapSet.size(@selected_ids) == 0}
                    class="btn btn-xs btn-ghost"
                  >
                    Limpar seleção
                  </button>
                </div>

                <div class="flex flex-wrap gap-2 items-start border-t border-base-300 pt-3">
                  <button
                    type="button"
                    id="share-brand"
                    phx-click="share_brand"
                    class="btn btn-primary btn-sm"
                  >
                    Link JPG para a marca
                  </button>
                  <button
                    type="button"
                    id="select-brand-picks"
                    phx-click="select_brand_picks"
                    class="btn btn-outline btn-sm"
                  >
                    Selecionar picks da marca
                  </button>
                  <button
                    type="button"
                    id="prepare-raw"
                    phx-click="prepare_raw"
                    class="btn btn-outline btn-sm"
                  >
                    Preparar download RAW
                  </button>
                  <a
                    :if={@raw_href}
                    id="raw-download-link"
                    href={@raw_href}
                    class="btn btn-sm btn-secondary"
                  >
                    Baixar ZIP de RAW
                  </a>
                </div>

                <div :if={@share_url} id="share-url-box" class="text-sm break-all">
                  <span class="opacity-60">URL da marca:</span>
                  <a
                    href={@share_url}
                    class="link link-primary font-mono"
                    target="_blank"
                    rel="noopener"
                  >{@share_url}</a>
                </div>
                <p :if={@share_error} id="share-error" class="text-sm text-error">{@share_error}</p>
                <p :if={@raw_error} id="raw-error" class="text-sm text-warning">{@raw_error}</p>
              </div>
            </div>

            <div class="card bg-base-100 shadow">
              <div class="card-body p-3 sm:p-4 gap-3">
                <div :if={@visible == []} class="text-center opacity-50 py-16">
                  Nenhuma foto neste filtro.
                </div>

                <div
                  id="post-grid"
                  class="grid grid-cols-3 sm:grid-cols-4 md:grid-cols-6 lg:grid-cols-8 gap-2"
                >
                  <button
                    :for={photo <- @visible}
                    type="button"
                    id={"post-photo-#{photo.id}"}
                    data-id={photo.id}
                    phx-hook=".PostSelect"
                    class={[
                      "relative rounded-md overflow-hidden ring-offset-2 ring-offset-base-100 transition focus:outline-none",
                      MapSet.member?(@selected_ids, photo.id) && "ring-2 ring-primary",
                      !MapSet.member?(@selected_ids, photo.id) &&
                        "ring-0 hover:ring-1 hover:ring-base-content/30"
                    ]}
                  >
                    <img
                      src={photo.web_path}
                      alt=""
                      class="w-full aspect-[3/2] object-cover pointer-events-none"
                      draggable="false"
                    />
                    <div class="absolute bottom-1 left-1 right-1 flex gap-0.5 flex-wrap pointer-events-none">
                      <span
                        :if={Map.get(@labels, photo.id)}
                        class="h-2.5 w-2.5 rounded-full ring-1 ring-white/80 shrink-0"
                        style={"background-color: #{Colors.hex(Map.get(@labels, photo.id))}"}
                      />
                      <span
                        :for={{color, count} <- Map.get(@tallies, photo.id, %{}) |> Enum.sort()}
                        class="text-[9px] font-bold text-white rounded px-0.5 leading-3"
                        style={"background-color: #{Colors.hex(color)}"}
                      >
                        {count}
                      </span>
                    </div>
                    <span class="absolute top-0.5 right-0.5 text-[9px] px-1 rounded bg-black/50 text-white tabular-nums">
                      {photo.seq}
                    </span>
                  </button>
                </div>
              </div>
            </div>

            <aside id="session-history" class="card bg-base-100 shadow">
              <div class="card-body p-4 gap-2">
                <h2 class="card-title text-sm">Histórico da sessão</h2>
                <p class="text-xs opacity-50">
                  Desfazer também por Ctrl+Z / Cmd+Z. Não some sozinho.
                </p>
                <ul :if={@history != []} class="text-sm space-y-1 max-h-48 overflow-y-auto">
                  <li
                    :for={entry <- @history}
                    id={"history-#{entry.id}"}
                    class="flex justify-between gap-2 opacity-80"
                  >
                    <span>{entry.summary}</span>
                    <span class="text-xs opacity-50 tabular-nums">
                      {Calendar.strftime(entry.at, "%H:%M:%S")}
                    </span>
                  </li>
                </ul>
                <p :if={@history == []} class="text-xs opacity-40 py-2">Nenhuma ação ainda.</p>
              </div>
            </aside>
          </section>
        </div>
      </div>

      <script :type={Phoenix.LiveView.ColocatedHook} name=".PostSelect">
        export default {
          mounted() {
            this.el.addEventListener("click", (e) => {
              e.preventDefault()
              this.pushEvent("select_photo", {
                id: this.el.dataset.id,
                shift: e.shiftKey
              })
            })
          }
        }
      </script>
    </div>
    """
  end
end
