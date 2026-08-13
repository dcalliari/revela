defmodule Revela.Repo.Migrations.AddExpiryToRawDownloads do
  use Ecto.Migration

  def up do
    now = DateTime.utc_now()

    alter table(:raw_downloads) do
      add :expires_at, :utc_datetime_usec, null: false, default: now
    end

    create index(:raw_downloads, [:expires_at])
  end

  def down do
    drop index(:raw_downloads, [:expires_at])

    alter table(:raw_downloads) do
      remove :expires_at
    end
  end
end
