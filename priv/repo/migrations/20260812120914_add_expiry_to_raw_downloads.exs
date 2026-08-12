defmodule Revela.Repo.Migrations.AddExpiryToRawDownloads do
  use Ecto.Migration

  def up do
    alter table(:raw_downloads) do
      add :expires_at, :utc_datetime_usec
    end

    now = DateTime.utc_now()
    repo().update_all("raw_downloads", set: [expires_at: now])

    create index(:raw_downloads, [:expires_at])
  end

  def down do
    drop index(:raw_downloads, [:expires_at])

    alter table(:raw_downloads) do
      remove :expires_at
    end
  end
end
