defmodule RevelaWeb.HostLiveDemoTest do
  use RevelaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  test "sem demo nao liga atalho window de demo_key", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/host")

    refute html =~ ~s(phx-window-keyup="demo_key")
    refute html =~ ~s(phx-key="d")
  end

  test "demo_fire recusado nao mostra notice de falha de escrita", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/host")

    html = render_click(view, "demo_fire", %{})
    refute html =~ "Falha ao gravar JPEG de demo"
  end
end
