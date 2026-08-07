defmodule RevelaWeb.PostLiveTest do
  use RevelaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Revela.Capture

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

  test "Ctrl+Z desfaz via keydown", %{conn: conn, editorial: editorial, a: a} do
    {:ok, view, _html} = live(conn, ~p"/post/#{editorial.id}")

    render_hook(view, "select_photo", %{"id" => to_string(a.id), "shift" => false})
    view |> element("#label-sel-1") |> render_click()
    assert Capture.labels_for_reviewer_in_editorial("host", editorial.id)[a.id] == 1

    render_keydown(view, "keydown", %{"key" => "z", "ctrlKey" => true, "metaKey" => false})
    assert Capture.labels_for_reviewer_in_editorial("host", editorial.id) == %{}
  end
end
