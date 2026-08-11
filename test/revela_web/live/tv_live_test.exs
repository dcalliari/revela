defmodule RevelaWeb.TvLiveTest do
  use RevelaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Revela.Capture

  setup do
    Capture.reset_host_viewer_state()
    {:ok, _editorial} = Capture.start_editorial("TV Test", "/tmp/tv-test")
    :ok
  end

  test "renderiza superficie de apresentacao sem controles de classificacao", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/tv")

    assert has_element?(view, "#tv-presentation")
    assert has_element?(view, "#tv-waiting")
    refute has_element?(view, "[phx-click=pick]")
    refute has_element?(view, "[phx-click=prev]")
    refute has_element?(view, "[phx-click=next]")
    refute has_element?(view, "#identity-form")
  end

  test "espelha mudanca de foto e go_live do Host via PubSub", %{conn: conn} do
    {:ok, photo_a} = Capture.create_photo(%{web_path: "/uploads/a.jpg"})
    {:ok, photo_b} = Capture.create_photo(%{web_path: "/uploads/b.jpg"})

    {:ok, tv, _html} = live(conn, ~p"/tv")
    assert has_element?(tv, "#tv-photo-#{photo_b.id}")
    assert has_element?(tv, "#tv-live-badge", "AO VIVO")

    {:ok, host, _html} = live(conn, ~p"/host")
    open_photo(host, photo_a)

    html = render(tv)
    assert html =~ "tv-photo-#{photo_a.id}"
    assert html =~ "ESPELHO"
    assert has_element?(tv, "#tv-idle-hint")
    assert has_element?(tv, "#tv-idle-seconds")

    render_click(element(host, "button", "ir ao vivo"))
    html = render(tv)
    assert html =~ "tv-photo-#{photo_b.id}"
    assert html =~ "AO VIVO"
    refute has_element?(tv, "#tv-idle-hint")
  end

  test "apos idle com follow off, /tv volta ao vivo sem afetar o Host", %{conn: conn} do
    {:ok, photo_a} = Capture.create_photo(%{web_path: "/uploads/idle-a.jpg"})
    {:ok, photo_b} = Capture.create_photo(%{web_path: "/uploads/idle-b.jpg"})

    {:ok, host, _html} = live(conn, ~p"/host")
    {:ok, tv, _html} = live(conn, ~p"/tv")

    open_photo(host, photo_a)
    assert render(tv) =~ "tv-photo-#{photo_a.id}"
    assert render(tv) =~ "ESPELHO"
    assert has_element?(tv, "#tv-idle-hint")

    %{socket: %{assigns: %{idle_gen: gen}}} = :sys.get_state(tv.pid)
    send(tv.pid, {:idle_return_live, gen})
    _ = :sys.get_state(tv.pid)

    assert render(tv) =~ "tv-photo-#{photo_b.id}"
    assert render(tv) =~ "AO VIVO"
    refute has_element?(tv, "#tv-idle-hint")

    # Host permanece na foto antiga
    assert has_element?(host, "#zoomer-host")
    host_html = render(host)
    assert host_html =~ photo_a.web_path
    refute host_html =~ "AO VIVO"
  end

  test "toque no /tv apos retorno por idle resincroniza com o Host mesmo sem novo broadcast",
       %{conn: conn} do
    {:ok, photo_a} = Capture.create_photo(%{web_path: "/uploads/resync-a.jpg"})
    {:ok, _photo_b} = Capture.create_photo(%{web_path: "/uploads/resync-b.jpg"})

    {:ok, host, _html} = live(conn, ~p"/host")
    {:ok, tv, _html} = live(conn, ~p"/tv")

    open_photo(host, photo_a)
    assert render(tv) =~ "tv-photo-#{photo_a.id}"
    assert render(tv) =~ "ESPELHO"

    %{socket: %{assigns: %{idle_gen: gen}}} = :sys.get_state(tv.pid)
    send(tv.pid, {:idle_return_live, gen})
    _ = :sys.get_state(tv.pid)

    assert render(tv) =~ "AO VIVO"
    # o Host nao mudou de estado: o broadcast_host_viewer/1 correspondente e
    # deduplicado, entao nao ha novo evento PubSub para o /tv reagir
    assert Capture.host_viewer_state() == %{photo_id: photo_a.id, follow: false, open: true}

    render_click(element(tv, "#tv-presentation"))

    html = render(tv)
    assert html =~ "tv-photo-#{photo_a.id}"
    assert html =~ "ESPELHO"
    assert has_element?(tv, "#tv-idle-hint")
  end

  test "reconectar em /tv apos retorno por idle resincroniza com o Host mesmo sem novo broadcast",
       %{conn: conn} do
    {:ok, photo_a} = Capture.create_photo(%{web_path: "/uploads/reconnect-a.jpg"})
    {:ok, _photo_b} = Capture.create_photo(%{web_path: "/uploads/reconnect-b.jpg"})

    {:ok, host, _html} = live(conn, ~p"/host")
    {:ok, tv, _html} = live(conn, ~p"/tv")

    open_photo(host, photo_a)

    %{socket: %{assigns: %{idle_gen: gen}}} = :sys.get_state(tv.pid)
    send(tv.pid, {:idle_return_live, gen})
    _ = :sys.get_state(tv.pid)
    assert render(tv) =~ "AO VIVO"
    assert Capture.host_viewer_state() == %{photo_id: photo_a.id, follow: false, open: true}

    {:ok, tv2, _html} = live(conn, ~p"/tv")

    html = render(tv2)
    assert html =~ "tv-photo-#{photo_a.id}"
    assert html =~ "ESPELHO"
  end

  test "interacao local reinicia o timer e mantem espelho", %{conn: conn} do
    {:ok, photo_a} = Capture.create_photo(%{web_path: "/uploads/bump-a.jpg"})
    {:ok, _photo_b} = Capture.create_photo(%{web_path: "/uploads/bump-b.jpg"})

    {:ok, host, _html} = live(conn, ~p"/host")
    {:ok, tv, _html} = live(conn, ~p"/tv")

    open_photo(host, photo_a)
    assert has_element?(tv, "#tv-idle-hint")

    render_click(element(tv, "#tv-presentation"))

    html = render(tv)
    assert html =~ "tv-photo-#{photo_a.id}"
    assert html =~ "ESPELHO"
    assert has_element?(tv, "#tv-idle-hint")
    assert has_element?(tv, "#tv-idle-seconds")
  end

  test "nova foto do Host parado nao reinicia idle nem desfaz AO VIVO do /tv", %{conn: conn} do
    {:ok, photo_a} = Capture.create_photo(%{web_path: "/uploads/park-a.jpg"})
    {:ok, _photo_b} = Capture.create_photo(%{web_path: "/uploads/park-b.jpg"})

    {:ok, host, _html} = live(conn, ~p"/host")
    {:ok, tv, _html} = live(conn, ~p"/tv")

    open_photo(host, photo_a)
    assert has_element?(tv, "#tv-idle-hint")

    %{socket: %{assigns: %{idle_deadline: deadline, idle_gen: gen}}} = :sys.get_state(tv.pid)
    assert is_integer(deadline)

    {:ok, photo_c} = Capture.create_photo(%{web_path: "/uploads/park-c.jpg"})
    _ = :sys.get_state(host.pid)
    _ = :sys.get_state(tv.pid)

    %{socket: %{assigns: tv_assigns}} = :sys.get_state(tv.pid)
    assert tv_assigns.idle_deadline == deadline
    assert tv_assigns.idle_gen == gen
    assert tv_assigns.follow == false
    assert tv_assigns.photo_id == photo_a.id
    assert has_element?(tv, "#tv-idle-hint")

    send(tv.pid, {:idle_return_live, gen})
    _ = :sys.get_state(tv.pid)

    assert render(tv) =~ "tv-photo-#{photo_c.id}"
    assert render(tv) =~ "AO VIVO"
    refute has_element?(tv, "#tv-idle-hint")

    {:ok, photo_d} = Capture.create_photo(%{web_path: "/uploads/park-d.jpg"})
    _ = :sys.get_state(host.pid)
    _ = :sys.get_state(tv.pid)

    # Host estacionado: broadcast no-op; /tv permanece ao vivo e avanca via :new_photo
    assert Capture.host_viewer_state() == %{photo_id: photo_a.id, follow: false, open: true}
    assert render(tv) =~ "tv-photo-#{photo_d.id}"
    assert render(tv) =~ "AO VIVO"
    refute has_element?(tv, "#tv-idle-hint")

    host_html = render(host)
    assert host_html =~ photo_a.web_path
    refute host_html =~ "AO VIVO"
  end

  test "timer idle cancelado (gen antigo) e ignorado", %{conn: conn} do
    {:ok, photo_a} = Capture.create_photo(%{web_path: "/uploads/stale-a.jpg"})
    {:ok, _photo_b} = Capture.create_photo(%{web_path: "/uploads/stale-b.jpg"})

    {:ok, host, _html} = live(conn, ~p"/host")
    {:ok, tv, _html} = live(conn, ~p"/tv")

    open_photo(host, photo_a)
    %{socket: %{assigns: %{idle_gen: stale_gen}}} = :sys.get_state(tv.pid)

    render_click(element(tv, "#tv-presentation"))
    %{socket: %{assigns: %{idle_gen: fresh_gen}}} = :sys.get_state(tv.pid)
    assert fresh_gen > stale_gen

    send(tv.pid, {:idle_return_live, stale_gen})
    _ = :sys.get_state(tv.pid)

    assert render(tv) =~ "tv-photo-#{photo_a.id}"
    assert render(tv) =~ "ESPELHO"
    assert has_element?(tv, "#tv-idle-hint")
  end

  test "subscribe no mount recebe estado retido do Host", %{conn: conn} do
    {:ok, photo_a} = Capture.create_photo(%{web_path: "/uploads/retain-a.jpg"})
    {:ok, _photo_b} = Capture.create_photo(%{web_path: "/uploads/retain-b.jpg"})

    {:ok, host, _html} = live(conn, ~p"/host")
    open_photo(host, photo_a)

    {:ok, tv, _html} = live(conn, ~p"/tv")
    assert render(tv) =~ "tv-photo-#{photo_a.id}"
    assert render(tv) =~ "ESPELHO"
    assert has_element?(tv, "#tv-idle-hint")
  end

  defp open_photo(view, photo) do
    render_click(element(view, ~s([phx-click=open][phx-value-id="#{photo.id}"])))
    assert has_element?(view, "#zoomer-host")
  end
end
