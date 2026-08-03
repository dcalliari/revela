defmodule Revela.Repo do
  use Ecto.Repo,
    otp_app: :revela,
    adapter: Ecto.Adapters.SQLite3
end
