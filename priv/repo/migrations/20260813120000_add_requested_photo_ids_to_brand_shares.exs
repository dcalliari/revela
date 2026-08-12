defmodule Revela.Repo.Migrations.AddRequestedPhotoIdsToBrandShares do
  use Ecto.Migration

  def change do
    alter table(:brand_shares) do
      add :requested_photo_ids, :text
    end
  end
end
