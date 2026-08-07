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

    send(tv.pid, :idle_return_live)
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
