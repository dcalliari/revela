defmodule RevelaWeb.Uploads do
  @moduledoc false

  @behaviour Plug

  @impl true
  def init(opts), do: Plug.Static.init(Keyword.put(opts, :from, default_dir()))

  @impl true
  def call(%Plug.Conn{request_path: <<"/uploads/", _rest::binary>>} = conn, opts) do
    opts = Plug.Static.init(Keyword.put(opts, :from, uploads_dir()))
    Plug.Static.call(conn, opts)
  end

  def call(conn, _opts), do: conn

  defp uploads_dir do
    Application.get_env(:revela, :uploads_dir, default_dir())
  end

  defp default_dir, do: Application.app_dir(:revela, "priv/static/uploads")
end
