defmodule RevelaWeb.BrandShareLive do
  @moduledoc """
  Galeria publica (tokenizada) de previews JPG para a marca classificar/selecionar.
  Identidade de revisor: `brand-<token>` (estavel por link).
  """
  use RevelaWeb, :live_view

  alias Revela.Capture
  alias Revela.Capture.BrandShare
  alias Revela.Delivery
  alias RevelaWeb.Colors

  @impl true
  def mount(%{"token" => token}, _session, socket) do
    case Delivery.get_brand_share(token) do
      nil ->
        {:ok,
         socket
         |> assign(:share, nil)
         |> assign(:photos, [])
         |> assign(:labels, %{})
         |> assign(:reviewer_id, nil)
         |> assign(:open_id, nil)
         |> assign(:page_title, "Link invalido")}

      share ->
        reviewer_id = "brand-#{share.token}"
        ids = BrandShare.decode_photo_ids(share)
        photos = Capture.get_photos_in_editorial(share.editorial_id, ids)
        labels = Capture.labels_for_reviewer_in_editorial(reviewer_id, share.editorial_id)

        {:ok,
         socket
         |> assign(:share, share)
         |> assign(:photos, photos)
         |> assign(:labels, labels)
         |> assign(:reviewer_id, reviewer_id)
         |> assign(:open_id, nil)
         |> assign(:page_title, share.label || "Selecao revela")}
    end
  end

  @impl true
  def handle_event("pick", %{"id" => id, "color" => color}, socket) do
    photo_id = String.to_integer(id)
    color = String.to_integer(color)

    if photo_id in Enum.map(socket.assigns.photos, & &1.id) do
      Capture.set_label(photo_id, socket.assigns.reviewer_id, "marca", color)
      labels = Map.put(socket.assigns.labels, photo_id, color)
      {:noreply, assign(socket, :labels, labels)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("clear", %{"id" => id}, socket) do
    photo_id = String.to_integer(id)

    if photo_id in Enum.map(socket.assigns.photos, & &1.id) do
      Capture.clear_label(photo_id, socket.assigns.reviewer_id)
      {:noreply, assign(socket, :labels, Map.delete(socket.assigns.labels, photo_id))}
    else
      {:noreply, socket}
    end
  end

  def handle_event("open", %{"id" => id}, socket) do
    {:noreply, assign(socket, :open_id, String.to_integer(id))}
  end

  def handle_event("close", _params, socket) do
    {:noreply, assign(socket, :open_id, nil)}
  end

  def handle_event("key", %{"key" => "Escape"}, socket) do
    {:noreply, assign(socket, :open_id, nil)}
  end

  def handle_event("key", _params, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <div class="min-h-dvh bg-neutral-950 text-neutral-100">
      <div :if={is_nil(@share)} class="max-w-lg mx-auto px-4 py-24 text-center">
        <p class="font-serif italic text-4xl text-neutral-500 lowercase">revela</p>
        <p class="mt-6 text-neutral-400">Este link de selecao nao existe ou expirou.</p>
      </div>

      <div :if={@share} class="max-w-6xl mx-auto px-3 sm:px-6 py-6 sm:py-10">
        <header class="mb-8 border-b border-white/10 pb-6">
          <p class="font-serif italic text-3xl sm:text-4xl lowercase tracking-tight">revela</p>
          <h1 class="mt-2 text-lg sm:text-xl font-medium text-neutral-200">
            {@share.label || "Selecao para a marca"}
          </h1>
          <p class="mt-1 text-sm text-neutral-500">
            {length(@photos)} previews · toque numa cor para marcar · 0 limpa
          </p>
        </header>

        <div :if={@photos == []} class="py-20 text-center text-neutral-500">
          Nenhuma foto nesta selecao.
        </div>

        <div
          id="brand-share-grid"
          class="grid grid-cols-2 sm:grid-cols-3 md:grid-cols-4 lg:grid-cols-5 gap-3"
        >
          <article
            :for={photo <- @photos}
            id={"brand-photo-#{photo.id}"}
            class="group relative"
          >
            <button
              type="button"
              phx-click="open"
              phx-value-id={photo.id}
              class="block w-full focus:outline-none focus-visible:ring-2 focus-visible:ring-white/60 rounded-sm overflow-hidden"
            >
              <%= if photo.web_path do %>
                <img
                  src={photo.web_path}
                  alt=""
                  loading="lazy"
                  decoding="async"
                  class="w-full aspect-[3/2] object-cover bg-neutral-900 transition duration-200 group-hover:brightness-110"
                />
              <% else %>
                <span class="flex w-full aspect-[3/2] items-center justify-center bg-neutral-900 text-xs text-neutral-500">
                  RAW sem preview
                </span>
              <% end %>
            </button>
            <div class="mt-2 flex items-center justify-center gap-1.5">
              <button
                :for={c <- Colors.all()}
                type="button"
                id={"brand-pick-#{photo.id}-#{c.value}"}
                phx-click="pick"
                phx-value-id={photo.id}
                phx-value-color={c.value}
                aria-label={c.name}
                class={[
                  "h-5 w-5 rounded-full transition ring-offset-2 ring-offset-neutral-950",
                  @labels[photo.id] == c.value && "ring-2 ring-white scale-110",
                  @labels[photo.id] != c.value && "opacity-70 hover:opacity-100"
                ]}
                style={"background-color: #{c.hex}"}
              />
              <button
                type="button"
                id={"brand-clear-#{photo.id}"}
                phx-click="clear"
                phx-value-id={photo.id}
                aria-label="Limpar"
                class="ml-1 text-[10px] uppercase tracking-wide text-neutral-500 hover:text-neutral-200"
              >
                0
              </button>
            </div>
          </article>
        </div>
      </div>

      <div
        :if={@share && @open_id}
        id="brand-lightbox"
        class="fixed inset-0 z-50 bg-black/95 flex flex-col"
        phx-window-keyup="key"
      >
        <% photo = Enum.find(@photos, &(&1.id == @open_id)) %>
        <div class="flex justify-end p-3">
          <button type="button" phx-click="close" class="btn btn-sm btn-ghost text-white">Fechar</button>
        </div>
        <div :if={photo} class="flex-1 flex items-center justify-center p-4">
          <%= if photo.web_path do %>
            <img src={photo.web_path} class="max-h-full max-w-full object-contain" />
          <% else %>
            <span class="text-neutral-500">RAW sem preview</span>
          <% end %>
        </div>
      </div>
    </div>
    """
  end
end
