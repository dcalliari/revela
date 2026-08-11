defmodule RevelaWeb.ViewerNavTest do
  use RevelaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Revela.Capture

  setup do
    {:ok, _editorial} = Capture.start_editorial("Nav Test", "/tmp/nav-test")
    {:ok, photo_a} = Capture.create_photo(%{web_path: "/uploads/a.jpg"})
    {:ok, photo_b} = Capture.create_photo(%{web_path: "/uploads/b.jpg"})
    {:ok, photo_c} = Capture.create_photo(%{web_path: "/uploads/c.jpg"})
    %{photos: [photo_a, photo_b, photo_c]}
  end

  describe "HostLive" do
    test "L jumps to latest and enables follow", %{conn: conn, photos: photos} do
      {:ok, view, _html} = live(conn, "/host")
      first = hd(photos)
      last = List.last(photos)

      render_click(view, "open", %{"id" => Integer.to_string(first.id)})
      assert has_element?(view, "button", "ir ao vivo")

      render_keyup(view, "key", %{"key" => "L"})

      assert has_element?(view, "button", "AO VIVO")
      assert has_element?(view, "span", "3 / 3")
      assert render(view) =~ last.web_path
    end

    test "l (lowercase) also goes live", %{conn: conn, photos: photos} do
      {:ok, view, _html} = live(conn, "/host")

      render_click(view, "open", %{"id" => Integer.to_string(hd(photos).id)})
      render_keyup(view, "key", %{"key" => "l"})
      assert has_element?(view, "button", "AO VIVO")
    end

    test "ArrowRight to last photo enables follow; new capture advances", %{
      conn: conn,
      photos: photos
    } do
      {:ok, view, _html} = live(conn, "/host")

      render_click(view, "open", %{"id" => Integer.to_string(Enum.at(photos, 1).id)})
      assert has_element?(view, "button", "ir ao vivo")
      assert has_element?(view, "span", "2 / 3")

      render_keyup(view, "key", %{"key" => "ArrowRight"})

      assert has_element?(view, "button", "AO VIVO")
      assert has_element?(view, "span", "3 / 3")

      {:ok, photo_d} = Capture.create_photo(%{web_path: "/uploads/d.jpg"})
      _ = :sys.get_state(view.pid)

      assert render(view) =~ photo_d.web_path
      assert has_element?(view, "button", "AO VIVO")
      assert has_element?(view, "span", "4 / 4")
    end

    test "import while follow advances idx to new last", %{conn: conn, photos: photos} do
      root =
        Path.join(
          System.tmp_dir!(),
          "revela-import-media-#{System.unique_integer([:positive])}"
        )

      source = Path.join(root, "card")
      File.mkdir_p!(source)
      jpeg = Path.join(source, "IMPORT_NEW.JPG")
      {_, 0} = System.cmd("magick", ["-size", "8x8", "xc:red", jpeg])

      previous = Application.get_env(:revela, :card_import_allowed_roots)

      on_exit(fn ->
        File.rm_rf(root)

        if is_nil(previous) do
          Application.delete_env(:revela, :card_import_allowed_roots)
        else
          Application.put_env(:revela, :card_import_allowed_roots, previous)
        end
      end)

      Application.put_env(:revela, :card_import_allowed_roots, [root])

      {:ok, view, _html} = live(conn, "/host")
      render_click(view, "open", %{"id" => Integer.to_string(List.last(photos).id)})
      assert has_element?(view, "button", "AO VIVO")
      assert has_element?(view, "span", "3 / 3")

      # Assert on the event reply itself: PubSub :new_photo only repairs later.
      html =
        view
        |> form("#card-import-form", %{path: source})
        |> render_submit()

      assert html =~ "AO VIVO"
      assert html =~ "4 / 4"
      refute html =~ ">3 / 4<"
    end

    test "viewer keyboard shortcuts have no visual indicators", %{conn: conn, photos: photos} do
      {:ok, view, _html} = live(conn, "/host")

      render_click(view, "open", %{"id" => Integer.to_string(List.last(photos).id)})

      refute has_element?(view, "#shortcuts-legend")
      assert has_element?(view, "button[aria-label='Limpar cor (0)']")
    end
  end

  describe "ReviewLive" do
    setup %{conn: conn} do
      conn =
        put_connect_params(conn, %{
          "reviewer_id" => "rev-nav-1",
          "reviewer_name" => "Ana"
        })

      %{conn: conn}
    end

    test "L jumps to latest and enables follow", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      assert has_element?(view, "button", "AO VIVO")

      render_keyup(view, "key", %{"key" => "ArrowLeft"})
      assert has_element?(view, "button", "ir ao vivo")

      render_keyup(view, "key", %{"key" => "L"})
      assert has_element?(view, "button", "AO VIVO")
      assert has_element?(view, "span", "3 / 3")
    end

    test "navigating to last photo enables follow; new capture advances", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      render_keyup(view, "key", %{"key" => "ArrowLeft"})
      render_keyup(view, "key", %{"key" => "ArrowLeft"})
      assert has_element?(view, "button", "ir ao vivo")
      assert has_element?(view, "span", "1 / 3")

      render_keyup(view, "key", %{"key" => "ArrowRight"})
      render_keyup(view, "key", %{"key" => "ArrowRight"})
      assert has_element?(view, "button", "AO VIVO")
      assert has_element?(view, "span", "3 / 3")

      {:ok, photo_d} = Capture.create_photo(%{web_path: "/uploads/d.jpg"})
      _ = :sys.get_state(view.pid)

      assert render(view) =~ photo_d.web_path
      assert has_element?(view, "button", "AO VIVO")
      assert has_element?(view, "span", "4 / 4")
    end

    test "viewer keyboard shortcuts have no visual indicators", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      refute has_element?(view, "#shortcuts-legend")
      assert has_element?(view, "button[aria-label='Limpar cor (0)']")
    end
  end
end
