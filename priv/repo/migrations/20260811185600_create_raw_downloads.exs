defmodule Revela.Repo.Migrations.CreateRawDownloads do
  use Ecto.Migration

  def change do
    create table(:raw_downloads) do
      add :token, :string, null: false
      add :editorial_id, references(:editorials, on_delete: :delete_all), null: false
      add :photo_ids, :text, null: false
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:raw_downloads, [:token])
  end
end
