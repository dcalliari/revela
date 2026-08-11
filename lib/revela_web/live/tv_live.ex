defmodule RevelaWeb.TvLive do
  @moduledoc """
  Superficie de apresentacao em janela separada (`/tv`).

  Display-only: espelha o visualizador do Host via PubSub, sem classificacao e
  sem Presence. Quando o Host esta ao vivo (ou com o viewer fechado), acompanha
  a foto mais recente; quando o Host folheia, segue a foto atual do Host.

  Item 7 so nesta superficie: apos ~30s parado fora do ao vivo, volta sozinho
  para a foto mais recente (com contagem visivel), sem consultar o Host —
  ninguem decide nesta tela, entao o timeout e incondicional. Host e
  celulares de revisores nao tem esse timeout.

  `Capture.broadcast_host_viewer/1` dedupe: um Host que nao mudou de estado
  nao gera novo evento PubSub. Depois do retorno por idle, o `/tv` fica
  mostrando "ao vivo" mesmo com o Host ainda parado ate que algo o traga de
  volta — nao ha novo broadcast so porque o Host nao mudou. Qualquer
  interacao local (`tv_activity`) e a reconexao (`mount/3`) por isso leem
  `Capture.host_viewer_state/0` direto (nao dependem do PubSub) e
  resincronizam sempre, mesmo que o estado seja identico ao ultimo
  broadcast — e o unico jeito do operador forcar o `/tv` a voltar a
  espelhar o Host sem precisar navegar o Host para algo diferente e voltar.
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
     |> assign(:idle_gen, 0)
     |> assign(:idle_ms, idle_ms())
     |> apply_host_viewer(host)}
  end

  @impl true
  def handle_event("tv_activity", _params, socket) do
    {:noreply, resync(socket)}
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

  def handle_info({:idle_tick, gen}, socket) do
    if gen == socket.assigns.idle_gen do
      {:noreply, tick_idle(socket)}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:idle_return_live, gen}, socket) do
    if gen == socket.assigns.idle_gen do
      photos = socket.assigns.photos

      {:noreply,
       socket
       |> cancel_idle()
       |> assign(follow: true, photo_id: latest_photo_id(photos), idle_remaining: nil)
       |> schedule_idle()}
    else
      {:noreply, socket}
    end
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

  defp apply_host_viewer(socket, state) do
    {follow, photo_id} = mirror_target(state, socket.assigns.photos)
    maybe_apply_mirror(socket, follow, photo_id)
  end

  defp mirror_target(%{open: false}, photos), do: {true, latest_photo_id(photos)}

  defp mirror_target(%{open: true, follow: follow} = state, photos),
    do: {follow, state.photo_id || latest_photo_id(photos)}

  defp maybe_apply_mirror(socket, follow, photo_id) do
    if socket.assigns[:follow] == follow and socket.assigns[:photo_id] == photo_id do
      socket
    else
      socket
      |> cancel_idle()
      |> assign(follow: follow, photo_id: photo_id)
      |> schedule_idle()
    end
  end

  defp maybe_follow_latest(socket) do
    if socket.assigns.follow do
      assign(socket, photo_id: latest_photo_id(socket.assigns.photos))
    else
      socket
    end
  end

  # le Capture.host_viewer_state/0 direto e reaplica incondicionalmente (nao
  # via maybe_apply_mirror), porque o broadcast do Host e deduplicado quando
  # o estado nao muda: sem essa leitura direta, uma interacao local no /tv
  # nao teria como perceber que o Host segue parado na mesma foto.
  defp resync(socket) do
    {follow, photo_id} = mirror_target(Capture.host_viewer_state(), socket.assigns.photos)

    socket
    |> cancel_idle()
    |> assign(follow: follow, photo_id: photo_id)
    |> schedule_idle()
  end

  defp schedule_idle(socket) do
    gen = socket.assigns.idle_gen + 1

    cond do
      not connected?(socket) or socket.assigns.follow ->
        assign(socket,
          idle_gen: gen,
          idle_ref: nil,
          idle_tick_ref: nil,
          idle_deadline: nil,
          idle_remaining: nil
        )

      true ->
        now = System.monotonic_time(:millisecond)
        deadline = now + socket.assigns.idle_ms
        return_ref = Process.send_after(self(), {:idle_return_live, gen}, socket.assigns.idle_ms)
        tick_ref = Process.send_after(self(), {:idle_tick, gen}, @tick_ms)

        assign(socket,
          idle_gen: gen,
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

      %{idle_deadline: deadline, idle_gen: gen} when is_integer(deadline) ->
        now = System.monotonic_time(:millisecond)
        remaining = remaining_seconds(deadline, now)

        tick_ref =
          if remaining > 0 do
            Process.send_after(self(), {:idle_tick, gen}, @tick_ms)
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

    assign(socket,
      idle_gen: socket.assigns.idle_gen + 1,
      idle_ref: nil,
      idle_tick_ref: nil,
      idle_deadline: nil
    )
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
