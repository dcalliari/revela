defmodule RevelaWeb.HostGridTest do
  use RevelaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Revela.Capture

  setup do
    {:ok, _editorial} = Capture.start_editorial("Host Grid", "/tmp/host-grid")

    photos =
      for i <- 1..30 do
        {:ok, photo} = Capture.create_photo(%{web_path: "/uploads/grid-#{i}.jpg"})
        photo
      end

    %{photos: photos}
  end

  test "pagina a grade alem das 24 mais recentes", %{conn: conn, photos: photos} do
    newest = List.last(photos)
    oldest = hd(photos)

    {:ok, view, _html} = live(conn, "/host")

    assert has_element?(view, "#host-photos-title", "Fotos (30)")
    assert has_element?(view, "#host-grid-pagination")
    assert has_element?(view, "#grid-page-label", "Página 1 de 2")
    assert render(view) =~ newest.web_path
    refute render(view) =~ oldest.web_path

    view |> element("#grid-next-page") |> render_click()

    assert has_element?(view, "#grid-page-label", "Página 2 de 2")
    assert render(view) =~ oldest.web_path

    view |> element("#grid-prev-page") |> render_click()

    assert has_element?(view, "#grid-page-label", "Página 1 de 2")
    refute render(view) =~ oldest.web_path
  end

  test "bolinhas de cor filtram a grade e resetam a pagina", %{conn: conn, photos: photos} do
    [p1, p2 | _] = photos
    newest = List.last(photos)

    {:ok, _} = Capture.set_label(p1.id, "host", "host", 0)
    {:ok, _} = Capture.set_label(p2.id, "rev", "Rev", 2)
    {:ok, _} = Capture.set_label(newest.id, "host", "host", 0)

    {:ok, view, _html} = live(conn, "/host")

    view |> element("#grid-next-page") |> render_click()
    assert has_element?(view, "#grid-page-label", "Página 2 de 2")

    view |> element("#color-filter-0") |> render_click()

    assert has_element?(view, "#color-filter-0[aria-pressed=true]")
    assert has_element?(view, "#host-photos-title", "Fotos (2)")
    refute has_element?(view, "#host-grid-pagination")
    html = render(view)
    assert html =~ p1.web_path
    assert html =~ newest.web_path
    refute html =~ p2.web_path

    view |> element("#color-filter-2") |> render_click()

    assert has_element?(view, "#host-photos-title", "Fotos (3)")
    html = render(view)
    assert html =~ p2.web_path

    view |> element("#color-filter-0") |> render_click()
    view |> element("#color-filter-2") |> render_click()

    assert has_element?(view, "#color-filter-0[aria-pressed=false]")
    assert has_element?(view, "#host-photos-title", "Fotos (30)")
    assert has_element?(view, "#grid-page-label", "Página 1 de 2")
  end

  test "label_changed atualiza tallies sem filtro e membership com filtro", %{
    conn: conn,
    photos: photos
  } do
    newest = List.last(photos)
    {:ok, view, _html} = live(conn, "/host")

    refute has_element?(view, "#grid-photo-#{newest.id} span")

    {:ok, _} = Capture.set_label(newest.id, "rev", "Rev", 1)
    send(view.pid, {:label_changed, newest.id})
    _ = :sys.get_state(view.pid)

    assert has_element?(view, "#grid-photo-#{newest.id} span", "1")

    view |> element("#color-filter-0") |> render_click()
    assert has_element?(view, "#host-photos-title", "Fotos (0)")
    assert has_element?(view, "#host-grid-empty")

    {:ok, _} = Capture.set_label(newest.id, "rev", "Rev", 0)
    send(view.pid, {:label_changed, newest.id})
    _ = :sys.get_state(view.pid)

    assert has_element?(view, "#host-photos-title", "Fotos (1)")
    assert has_element?(view, "#grid-photo-#{newest.id}")
    refute has_element?(view, "#host-grid-empty")
  end

  test "recusa import do cartao fora das raizes de midia", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/host")

    view
    |> form("#card-import-form", %{path: "/tmp/not-a-removable-card"})
    |> render_submit()

    html = render(view)
    assert html =~ "raízes de mídia permitidas"
    assert html =~ "/tmp/not-a-removable-card"
  end
end
