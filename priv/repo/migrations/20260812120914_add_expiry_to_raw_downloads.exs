defmodule Revela.Repo.Migrations.AddExpiryToRawDownloads do
  use Ecto.Migration

  def change do
    alter table(:raw_downloads) do
      add :expires_at, :utc_datetime_usec, null: false
    end

    create index(:raw_downloads, [:expires_at])
  end
end
