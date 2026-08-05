defmodule Revela.Capture.Editorial do
  use Ecto.Schema
  import Ecto.Changeset

  schema "editorials" do
    field :name, :string
    field :folder, :string
    field :started_at, :utc_datetime_usec
    field :finished_at, :utc_datetime_usec

    has_many :photos, Revela.Capture.Photo

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(editorial, attrs) do
    editorial
    |> cast(attrs, [:name, :folder, :started_at, :finished_at])
    |> validate_required([:name, :folder, :started_at])
  end
end
