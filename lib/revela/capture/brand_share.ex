defmodule Revela.Capture.BrandShare do
  @moduledoc """
  Link compartilhavel de previews JPG para a marca revisar uma selecao
  (intervalo ou pasta de cor) de um editorial. Persistido por token estavel.
  """

  use Ecto.Schema
  import Ecto.Changeset

  schema "brand_shares" do
    field :token, :string
    field :photo_ids, :string
    field :label, :string

    belongs_to :editorial, Revela.Capture.Editorial

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(share, attrs) do
    share
    |> cast(attrs, [:token, :editorial_id, :photo_ids, :label])
    |> validate_required([:token, :editorial_id, :photo_ids])
    |> unique_constraint(:token)
    |> foreign_key_constraint(:editorial_id)
  end

  @doc "Decodifica a lista de ids persistida em JSON."
  def decode_photo_ids(%__MODULE__{photo_ids: raw}) when is_binary(raw) do
    case Jason.decode(raw) do
      {:ok, ids} when is_list(ids) ->
        Enum.flat_map(ids, fn
          id when is_integer(id) ->
            [id]

          id when is_binary(id) ->
            case Integer.parse(id) do
              {n, ""} -> [n]
              _ -> []
            end

          _ ->
            []
        end)

      _ ->
        []
    end
  end

  def encode_photo_ids(ids) when is_list(ids), do: Jason.encode!(ids)
end
