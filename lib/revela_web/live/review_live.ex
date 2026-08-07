defmodule RevelaWeb.ReviewLive do
  @moduledoc """
  Tela de revisao ao vivo (mobile-first). Cada revisor tem a sua identidade leve
  guardada no dispositivo e classifica as fotos com as suas proprias cores.
  Modo "ao vivo" acompanha a foto mais recente conforme ela e disparada; navegar
  para tras pausa o modo ao vivo para permitir corrigir a classificacao.
  """
  use RevelaWeb, :live_view

  alias Revela.Capture
  alias RevelaWeb.{Presence, ViewerComponents}

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      params = get_connect_params(socket) || %{}
      rid = params["reviewer_id"]
      rname = params["reviewer_name"]

      if is_binary(rid) and rid != "" do
        Capture.subscribe_photos()
        Presence.track_reviewer(self(), rid, rname || "anon")

        photos = Capture.list_photos()

        {:ok,
         socket
         |> assign(
           identified: true,
           reviewer_id: rid,
           reviewer_name: rname,
           photos: photos,
           labels: Capture.labels_for_reviewer(rid),
           idx: max(length(photos) - 1, 0),
           follow: true
         )}
      else
        {:ok, assign(socket, identified: false)}
      end
    else
      {:ok, assign(socket, identified: false)}
    end
  end

  @impl true
  def handle_event("pick", %{"color" => c}, socket) do
    color = String.to_integer(c)

    case current_photo(socket.assigns) do
      nil ->
        {:noreply, socket}

      photo ->
        Capture.set_label(
          photo.id,
          socket.assigns.reviewer_id,
          socket.assigns.reviewer_name,
          color
        )

        labels = Map.put(socket.assigns.labels, photo.id, color)

        # avanca para a proxima foto; se ela for a mais recente, religa o ao vivo
        last = max(length(socket.assigns.photos) - 1, 0)
        next_idx = min(socket.assigns.idx + 1, last)

        {:noreply, assign(socket, labels: labels, idx: next_idx, follow: next_idx == last)}
    end
  end

  def handle_event("clear", _params, socket) do
    case current_photo(socket.assigns) do
      nil ->
        {:noreply, socket}

      photo ->
        Capture.clear_label(photo.id, socket.assigns.reviewer_id)
        {:noreply, assign(socket, labels: Map.delete(socket.assigns.labels, photo.id))}
    end
  end

  def handle_event("prev", _params, socket) do
    {:noreply, assign(socket, idx: max(socket.assigns.idx - 1, 0), follow: false)}
  end

  def handle_event("next", _params, socket) do
    last = max(length(socket.assigns.photos) - 1, 0)
    {:noreply, assign(socket, idx: min(socket.assigns.idx + 1, last))}
  end

  def handle_event("go_live", _params, socket) do
    last = max(length(socket.assigns.photos) - 1, 0)
    {:noreply, assign(socket, idx: last, follow: true)}
  end

  # atalhos de teclado (util no laptop): 1..5 = cores, setas = navegar, 0 = limpar
  def handle_event("key", %{"key" => key}, socket) do
    case key do
      k when k in ~w(1 2 3 4 5) ->
        handle_event("pick", %{"color" => Integer.to_string(String.to_integer(k) - 1)}, socket)

      "ArrowLeft" ->
        handle_event("prev", %{}, socket)

      "ArrowRight" ->
        handle_event("next", %{}, socket)

      k when k in ["0", "Backspace", "Delete"] ->
        handle_event("clear", %{}, socket)

      _ ->
        {:noreply, socket}
    end
  end

  @impl true
  def handle_info({:new_photo, _photo}, socket) do
    photos = Capture.list_photos()
    idx = if socket.assigns.follow, do: max(length(photos) - 1, 0), else: socket.assigns.idx
    {:noreply, assign(socket, photos: photos, idx: idx)}
  end

  def handle_info(:session_reset, socket) do
    if Map.get(socket.assigns, :identified) do
      photos = Capture.list_photos()

      {:noreply,
       assign(socket,
         photos: photos,
         idx: 0,
         follow: true,
         labels: Capture.labels_for_reviewer(socket.assigns.reviewer_id)
       )}
    else
      {:noreply, socket}
    end
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  # ── helpers ──────────────────────────────────────────────────────────────────

  defp current_photo(%{photos: photos, idx: idx}), do: Enum.at(photos, idx)
  defp current_photo(_), do: nil

  # ── render ───────────────────────────────────────────────────────────────────

  @impl true
  def render(%{identified: false} = assigns) do
    ~H"""
    <div class="min-h-dvh flex items-center justify-center bg-base-300 p-6">
      <form
        id="identity-form"
        phx-hook="Identity"
        class="card bg-base-100 shadow-xl w-full max-w-sm"
      >
        <div class="card-body gap-4">
          <h1 class="card-title text-xl">Entrar na sessao</h1>
          <p class="text-sm opacity-70">
            Escolha um nome para aparecer no estudio. Suas cores ficam so suas.
          </p>
          <input
            name="name"
            autocomplete="name"
            placeholder="Seu nome"
            class="input input-bordered w-full"
            required
          />
          <button type="submit" class="btn btn-primary w-full">Entrar</button>
        </div>
      </form>
    </div>
    """
  end

  def render(assigns) do
    ~H"""
    <ViewerComponents.viewer
      photo={current_photo(assigns)}
      count={length(@photos)}
      idx={@idx}
      follow={@follow}
      labels={@labels}
      title={@reviewer_name}
    />
    """
  end
end
