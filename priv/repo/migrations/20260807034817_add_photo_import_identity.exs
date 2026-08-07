defmodule Revela.Repo.Migrations.AddPhotoImportIdentity do
  use Ecto.Migration

  def change do
    alter table(:photos) do
      add :source_hash, :string
      add :original_filename, :string
    end

    # Re-import do mesmo arquivo no mesmo editorial nao cria duplicata.
    # source_hash nulo (captura tethered) fica de fora do indice.
    create unique_index(:photos, [:editorial_id, :source_hash],
             name: :photos_editorial_source_hash_index,
             where: "source_hash IS NOT NULL"
           )
  end
end
