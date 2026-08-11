defmodule Revela.Repo.Migrations.AddPhotosRawPathUniqueIndex do
  use Ecto.Migration

  def change do
    create unique_index(:photos, [:raw_path],
             where: "raw_path IS NOT NULL AND raw_path != ''",
             name: :photos_raw_path_unique_index
           )
  end
end
