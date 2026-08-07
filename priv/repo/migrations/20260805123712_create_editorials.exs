defmodule Revela.Repo.Migrations.CreateEditorials do
  use Ecto.Migration

  def change do
    create table(:editorials) do
      add :name, :string, null: false
      add :folder, :string, null: false
      add :started_at, :utc_datetime_usec, null: false
      add :finished_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:editorials, ["(1)"],
             where: "finished_at IS NULL",
             name: :editorials_active_index
           )

    alter table(:photos) do
      add :editorial_id, references(:editorials, on_delete: :nilify_all)
    end

    create index(:photos, [:editorial_id])
  end
end
