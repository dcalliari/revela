defmodule RevelaWeb.BrandShareLiveTest do
  use RevelaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Revela.{Capture, Delivery}

  setup do
    {:ok, editorial} = Capture.start_editorial("Marca", "/tmp/marca-#{System.unique_integer()}")
    {:ok, a} = Capture.create_photo(%{web_path: "/uploads/m-a.jpg"})
    {:ok, b} = Capture.create_photo(%{web_path: "/uploads/m-b.jpg"})
    {:ok, share, path} = Delivery.create_brand_share(editorial.id, [a.id, b.id], label: "Looks")
    %{share: share, path: path, a: a, b: b, editorial: editorial}
  end

  test "mostra a grade tokenizada e aceita classificacao da marca", %{
    conn: conn,
    path: path,
    share: share,
    a: a
  } do
    {:ok, view, html} = live(conn, path)
    assert html =~ "Looks"
    assert has_element?(view, "#brand-share-grid")
    assert has_element?(view, "#brand-photo-#{a.id}")
    assert has_element?(view, "#brand-photo-#{a.id} img[loading='lazy'][decoding='async']")

    view |> element("#brand-pick-#{a.id}-2") |> render_click()

    labels = Capture.labels_for_reviewer_in_editorial("brand-#{share.token}", share.editorial_id)
    assert labels[a.id] == 2
  end

  test "token invalido", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/share/nao-existe")
    assert html =~ "nao existe"
  end
end
