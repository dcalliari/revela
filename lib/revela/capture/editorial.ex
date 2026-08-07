defmodule Revela.Capture.Editorial do
  @moduledoc """
  Sessao de revisao fotografica. No maximo uma linha com `finished_at` nulo
  (indice parcial `editorials_active_index`). Fotos e labels nao sao apagadas
  ao finalizar — so deixam de ser a sessao ativa.
  """

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
    |> unique_constraint(:finished_at, name: :editorials_active_index)
  end
end
