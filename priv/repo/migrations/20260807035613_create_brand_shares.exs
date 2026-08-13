defmodule Revela.Repo.Migrations.CreateBrandShares do
  use Ecto.Migration

  def change do
    create table(:brand_shares) do
      add :token, :string, null: false
      add :editorial_id, references(:editorials, on_delete: :delete_all), null: false
      add :photo_ids, :string, null: false
      add :label, :string

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:brand_shares, [:token])
    create index(:brand_shares, [:editorial_id])
  end
end
