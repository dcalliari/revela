defmodule RevelaWeb.PageController do
  use RevelaWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
