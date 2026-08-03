defmodule Revela.Capture.Photo do
  use Ecto.Schema
  import Ecto.Changeset

  schema "photos" do
    field :seq, :integer
    field :web_path, :string
    field :original_path, :string
    field :raw_path, :string
    field :shot_at, :utc_datetime_usec

    has_many :labels, Revela.Capture.Label

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(photo, attrs) do
    photo
    |> cast(attrs, [:seq, :web_path, :original_path, :raw_path, :shot_at])
    |> validate_required([:seq, :web_path])
    |> unique_constraint(:seq)
  end
end
