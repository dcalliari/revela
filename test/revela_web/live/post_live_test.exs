defmodule RevelaWeb.PostLiveTest do
  use RevelaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Revela.{Capture, Delivery}
  alias RevelaWeb.Colors

  setup do
    {:ok, editorial} = Capture.start_editorial("Pos", "/tmp/pos-#{System.unique_integer()}")
    {:ok, a} = Capture.create_photo(%{web_path: "/uploads/pos-a.jpg"})
    {:ok, b} = Capture.create_photo(%{web_path: "/uploads/pos-b.jpg"})
    {:ok, c} = Capture.create_photo(%{web_path: "/uploads/pos-c.jpg"})
    Capture.finish_editorial()
    %{editorial: editorial, a: a, b: b, c: c}
  end

  test "lista o editorial finalizado e a grade completa", %{
    conn: conn,
    editorial: editorial,
    a: a
  } do
    {:ok, view, _html} = live(conn, ~p"/post/#{editorial.id}")

    assert has_element?(view, "#post-root")
    assert has_element?(view, "#post-grid")
    assert has_element?(view, "#post-photo-#{a.id}")
    assert has_element?(view, "#session-history")
    assert has_element?(view, "#post-undo")
  end

  test "selecao contigua por shift e rotulo na selecao com historico/undo", %{
    conn: conn,
    editorial: editorial,
    a: a,
    b: b,
    c: c
  } do
    {:ok, view, _html} = live(conn, ~p"/post/#{editorial.id}")

    render_hook(view, "select_photo", %{"id" => to_string(a.id), "shift" => false})
    render_hook(view, "select_photo", %{"id" => to_string(c.id), "shift" => true})

    assert view |> element("#selection-count") |> render() =~ "3"

    view |> element("#label-sel-3") |> render_click()

    assert Capture.labels_for_reviewer_in_editorial("host", editorial.id) == %{
             a.id => 3,
             b.id => 3,
             c.id => 3
           }

    assert has_element?(view, "#session-history li")
    assert view |> element("#post-undo") |> render() =~ "Desfazer"

    view |> element("#post-undo") |> render_click()

    assert Capture.labels_for_reviewer_in_editorial("host", editorial.id) == %{}
  end

  test "filtro por cor", %{conn: conn, editorial: editorial, a: a, b: b} do
    Capture.set_label(a.id, "host", "host", 0)
    {:ok, view, _html} = live(conn, ~p"/post/#{editorial.id}")

    view |> element("#filter-0") |> render_click()
    assert has_element?(view, "#post-photo-#{a.id}")
    refute has_element?(view, "#post-photo-#{b.id}")
  end

  test "cria link local para a marca a partir da selecao", %{
    conn: conn,
    editorial: editorial,
    a: a,
    b: b
  } do
    {:ok, view, _html} = live(conn, ~p"/post/#{editorial.id}")

    render_hook(view, "select_photo", %{"id" => to_string(a.id), "shift" => false})
    render_hook(view, "select_photo", %{"id" => to_string(b.id), "shift" => true})
    view |> element("#share-brand") |> render_click()

    assert has_element?(view, "#share-url-box a")
    html = view |> element("#share-url-box a") |> render()
    assert html =~ "/share/"
  end

  test "prepare_raw exige selecao e raw_path", %{conn: conn, editorial: editorial, a: a} do
    {:ok, view, _html} = live(conn, ~p"/post/#{editorial.id}")

    view |> element("#prepare-raw") |> render_click()
    assert has_element?(view, "#raw-error")

    render_hook(view, "select_photo", %{"id" => to_string(a.id), "shift" => false})
    view |> element("#prepare-raw") |> render_click()
    assert has_element?(view, "#raw-error")
    refute has_element?(view, "#raw-download-link")
  end

  test "muda selecao/filtro limpa link RAW preparado", %{
    conn: conn,
    editorial: editorial,
    a: a,
    b: b
  } do
    dir = Path.join(System.tmp_dir!(), "revela-post-raw-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    raw = Path.join(dir, "shot.cr2")
    File.write!(raw, <<1, 2, 3>>)

    {:ok, a} =
      a
      |> Ecto.Changeset.change(%{raw_path: raw})
      |> Revela.Repo.update()

    {:ok, view, _html} = live(conn, ~p"/post/#{editorial.id}")

    render_hook(view, "select_photo", %{"id" => to_string(a.id), "shift" => false})
    view |> element("#prepare-raw") |> render_click()
    assert has_element?(view, "#raw-download-link")

    render_hook(view, "select_photo", %{"id" => to_string(b.id), "shift" => false})
    refute has_element?(view, "#raw-download-link")
    refute has_element?(view, "#raw-error")

    render_hook(view, "select_photo", %{"id" => to_string(a.id), "shift" => false})
    view |> element("#prepare-raw") |> render_click()
    assert has_element?(view, "#raw-download-link")

    view |> element("#clear-selection") |> render_click()
    refute has_element?(view, "#raw-download-link")

    render_hook(view, "select_photo", %{"id" => to_string(a.id), "shift" => false})
    view |> element("#prepare-raw") |> render_click()
    assert has_element?(view, "#raw-download-link")

    view |> element("#filter-all") |> render_click()
    refute has_element?(view, "#raw-download-link")
  end

  test "Ctrl+Z desfaz via keydown", %{conn: conn, editorial: editorial, a: a} do
    {:ok, view, _html} = live(conn, ~p"/post/#{editorial.id}")

    render_hook(view, "select_photo", %{"id" => to_string(a.id), "shift" => false})
    view |> element("#label-sel-1") |> render_click()
    assert Capture.labels_for_reviewer_in_editorial("host", editorial.id)[a.id] == 1

    render_keydown(view, "keydown", %{"key" => "z", "ctrlKey" => true, "metaKey" => false})
    assert Capture.labels_for_reviewer_in_editorial("host", editorial.id) == %{}
  end

  test "seleciona picks da marca, reseta filtro e ancora no menor seq", %{
    conn: conn,
    editorial: editorial,
    a: a,
    b: b,
    c: c
  } do
    {:ok, share, _} = Delivery.create_brand_share(editorial.id, [a.id, b.id, c.id])
    Capture.set_label(c.id, "brand-#{share.token}", "marca", 2)
    Capture.set_label(a.id, "brand-#{share.token}", "marca", 1)
    Capture.set_label(b.id, "host", "host", 0)

    {:ok, view, html} = live(conn, ~p"/post/#{editorial.id}")

    assert has_element?(view, "#select-brand-picks")
    assert html =~ Colors.hex(2)

    view |> element("#filter-0") |> render_click()
    refute has_element?(view, "#post-photo-#{a.id}")

    view |> element("#select-brand-picks") |> render_click()
    assert view |> element("#selection-count") |> render() =~ "2"
    assert has_element?(view, "#post-photo-#{a.id}")
    assert has_element?(view, "#post-photo-#{c.id}")
  end

  test "atualiza grade e tallies via PubSub", %{conn: conn} do
    {:ok, editorial} =
      Capture.start_editorial("Pos-live", "/tmp/pos-live-#{System.unique_integer()}")

    {:ok, a} = Capture.create_photo(%{web_path: "/uploads/pos-live-a.jpg"})
    {:ok, view, _html} = live(conn, ~p"/post/#{editorial.id}")

    assert has_element?(view, "#post-photo-#{a.id}")

    {:ok, b} = Capture.create_photo(%{web_path: "/uploads/pos-live-b.jpg"})
    assert has_element?(view, "#post-photo-#{b.id}")

    {:ok, share, _} = Delivery.create_brand_share(editorial.id, [a.id])
    Capture.set_label(a.id, "brand-#{share.token}", "marca", 4)

    assert view |> element("#post-photo-#{a.id}") |> render() =~ Colors.hex(4)
  end
end
