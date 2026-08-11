defmodule Revela.Capture.Photo do
  use Ecto.Schema
  import Ecto.Changeset

  schema "photos" do
    field :seq, :integer
    field :web_path, :string
    field :original_path, :string
    field :raw_path, :string
    field :source_hash, :string
    field :original_filename, :string
    field :shot_at, :utc_datetime_usec

    belongs_to :editorial, Revela.Capture.Editorial
    has_many :labels, Revela.Capture.Label

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(photo, attrs) do
    photo
    |> cast(attrs, [
      :seq,
      :web_path,
      :original_path,
      :raw_path,
      :source_hash,
      :original_filename,
      :shot_at,
      :editorial_id
    ])
    |> validate_required([:seq, :web_path])
    |> unique_constraint(:seq)
    |> unique_constraint(:raw_path, name: :photos_raw_path_unique_index)
    |> unique_constraint(:source_hash, name: :photos_editorial_source_hash_index)
  end
end
