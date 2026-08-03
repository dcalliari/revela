defmodule Revela.Capture.Label do
  use Ecto.Schema
  import Ecto.Changeset

  # cores no schema do darktable: 0=vermelho 1=amarelo 2=verde 3=azul 4=roxo
  @colors 0..4

  schema "labels" do
    field :reviewer_id, :string
    field :reviewer_name, :string
    field :color, :integer

    belongs_to :photo, Revela.Capture.Photo

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(label, attrs) do
    label
    |> cast(attrs, [:photo_id, :reviewer_id, :reviewer_name, :color])
    |> validate_required([:photo_id, :reviewer_id, :color])
    |> validate_inclusion(:color, @colors)
    |> unique_constraint([:photo_id, :reviewer_id])
  end

  def colors, do: @colors
end
