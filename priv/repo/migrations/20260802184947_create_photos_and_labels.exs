defmodule Revela.Repo.Migrations.CreatePhotosAndLabels do
  use Ecto.Migration

  def change do
    create table(:photos) do
      add :seq, :integer, null: false
      add :web_path, :string, null: false
      add :original_path, :string
      add :raw_path, :string
      add :shot_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:photos, [:seq])

    create table(:labels) do
      add :photo_id, references(:photos, on_delete: :delete_all), null: false
      add :reviewer_id, :string, null: false
      add :reviewer_name, :string
      # cor no schema do darktable: 0=vermelho 1=amarelo 2=verde 3=azul 4=roxo
      add :color, :integer, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:labels, [:photo_id, :reviewer_id])
    create index(:labels, [:reviewer_id])
  end
end
