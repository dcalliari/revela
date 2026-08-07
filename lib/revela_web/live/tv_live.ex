defmodule RevelaWeb.TvLive do
  @moduledoc """
  Superficie de apresentacao em janela separada (`/tv`).

  Display-only: espelha o visualizador do Host via PubSub, sem classificacao e
  sem Presence. Quando o Host esta ao vivo (ou com o viewer fechado), acompanha
  a foto mais recente; quando o Host folheia, segue a foto atual do Host.

  Item 7 so nesta superficie: apos ~30s parado fora do ao vivo, volta sozinho
  para a foto mais recente (com contagem visivel). Qualquer interacao local
  reinicia o timer. Host e celulares de revisores nao tem esse timeout.
  """
  use RevelaWeb, :live_view

  alias Revela.Capture
  alias RevelaWeb.ViewerComponents

  @default_idle_ms 30_000
  @tick_ms 250

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Capture.subscribe_photos()
      Capture.subscribe_host_viewer()
    end

    photos = Capture.list_photos()
    host = Capture.host_viewer_state()

    {:ok,
     socket
     |> assign(:photos, photos)
     |> assign(:idle_ref, nil)
     |> assign(:idle_tick_ref, nil)
     |> assign(:idle_deadline, nil)
     |> assign(:idle_remaining, nil)
     |> assign(:idle_ms, idle_ms())
     |> apply_host_viewer(host)}
  end

  @impl true
  def handle_event("tv_activity", _params, socket) do
    {:noreply, bump_idle(socket)}
  end

  @impl true
  def handle_info({:host_viewer, state}, socket) do
    {:noreply, apply_host_viewer(socket, state)}
  end

  def handle_info({:new_photo, _photo}, socket) do
    photos = Capture.list_photos()

    socket =
      socket
      |> assign(:photos, photos)
      |> maybe_follow_latest()

    {:noreply, socket}
  end

  def handle_info(:session_reset, socket) do
    photos = Capture.list_photos()

    {:noreply,
     socket
     |> assign(:photos, photos)
     |> cancel_idle()
     |> assign(follow: true, photo_id: latest_photo_id(photos), idle_remaining: nil)
     |> schedule_idle()}
  end

  def handle_info(:idle_tick, socket) do
    {:noreply, tick_idle(socket)}
  end

  def handle_info(:idle_return_live, socket) do
    photos = socket.assigns.photos

    {:noreply,
     socket
     |> cancel_idle()
     |> assign(follow: true, photo_id: latest_photo_id(photos), idle_remaining: nil)
     |> schedule_idle()}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <ViewerComponents.presentation
      photo={current_photo(assigns)}
      count={length(@photos)}
      idx={current_idx(assigns)}
      follow={@follow}
      idle_remaining={@idle_remaining}
      fs_id="fs-tv"
    />
    """
  end

  # ── helpers ──────────────────────────────────────────────────────────────────

  defp apply_host_viewer(socket, %{open: false}) do
    photos = socket.assigns.photos

    socket
    |> cancel_idle()
    |> assign(follow: true, photo_id: latest_photo_id(photos), idle_remaining: nil)
    |> schedule_idle()
  end

  defp apply_host_viewer(socket, %{open: true, follow: true} = state) do
    photos = socket.assigns.photos
    photo_id = state.photo_id || latest_photo_id(photos)

    socket
    |> cancel_idle()
    |> assign(follow: true, photo_id: photo_id, idle_remaining: nil)
    |> schedule_idle()
  end

  defp apply_host_viewer(socket, %{open: true, follow: false} = state) do
    photos = socket.assigns.photos
    photo_id = state.photo_id || latest_photo_id(photos)

    socket
    |> cancel_idle()
    |> assign(follow: false, photo_id: photo_id)
    |> schedule_idle()
  end

  defp maybe_follow_latest(socket) do
    if socket.assigns.follow do
      assign(socket, photo_id: latest_photo_id(socket.assigns.photos))
    else
      socket
    end
  end

  defp bump_idle(socket) do
    if socket.assigns.follow do
      socket
    else
      socket
      |> cancel_idle()
      |> schedule_idle()
    end
  end

  defp schedule_idle(socket) do
    if socket.assigns.follow do
      assign(socket, idle_ref: nil, idle_tick_ref: nil, idle_deadline: nil, idle_remaining: nil)
    else
      now = System.monotonic_time(:millisecond)
      deadline = now + socket.assigns.idle_ms
      return_ref = Process.send_after(self(), :idle_return_live, socket.assigns.idle_ms)
      tick_ref = Process.send_after(self(), :idle_tick, @tick_ms)

      assign(socket,
        idle_ref: return_ref,
        idle_tick_ref: tick_ref,
        idle_deadline: deadline,
        idle_remaining: remaining_seconds(deadline, now)
      )
    end
  end

  defp tick_idle(socket) do
    case socket.assigns do
      %{follow: true} ->
        assign(socket, idle_tick_ref: nil, idle_remaining: nil)

      %{idle_deadline: deadline} when is_integer(deadline) ->
        now = System.monotonic_time(:millisecond)
        remaining = remaining_seconds(deadline, now)

        tick_ref =
          if remaining > 0 do
            Process.send_after(self(), :idle_tick, @tick_ms)
          end

        assign(socket, idle_tick_ref: tick_ref, idle_remaining: remaining)

      _ ->
        assign(socket, idle_tick_ref: nil)
    end
  end

  defp cancel_idle(socket) do
    case socket.assigns[:idle_ref] do
      ref when is_reference(ref) -> Process.cancel_timer(ref)
      _ -> :ok
    end

    case socket.assigns[:idle_tick_ref] do
      ref when is_reference(ref) -> Process.cancel_timer(ref)
      _ -> :ok
    end

    assign(socket, idle_ref: nil, idle_tick_ref: nil, idle_deadline: nil)
  end

  defp remaining_seconds(deadline, now) do
    max(0, div(deadline - now + 999, 1000))
  end

  defp latest_photo_id([]), do: nil
  defp latest_photo_id(photos), do: List.last(photos).id

  defp current_photo(%{photos: photos, photo_id: photo_id}) when not is_nil(photo_id) do
    Enum.find(photos, &(&1.id == photo_id)) || List.last(photos)
  end

  defp current_photo(%{photos: photos}), do: List.last(photos)

  defp current_idx(%{photos: photos} = assigns) do
    photo = current_photo(assigns)

    case photo && Enum.find_index(photos, &(&1.id == photo.id)) do
      nil -> 0
      idx -> idx
    end
  end

  defp idle_ms do
    Application.get_env(:revela, :tv_idle_ms, @default_idle_ms)
  end
end
