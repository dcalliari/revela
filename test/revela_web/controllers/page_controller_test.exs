defmodule RevelaWeb.PageControllerTest do
  use RevelaWeb.ConnCase

  import Phoenix.LiveViewTest

  test "GET /", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")
    assert has_element?(view, "#identity-form")
  end
end
