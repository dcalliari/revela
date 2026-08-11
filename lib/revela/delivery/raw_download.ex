defmodule Revela.Delivery.RawDownload do
  use Ecto.Schema
  import Ecto.Changeset

  schema "raw_downloads" do
    field :token, :string
    field :photo_ids, :string
    belongs_to :editorial, Revela.Capture.Editorial
    timestamps(type: :utc_datetime_usec)
  end

  def changeset(download, attrs) do
    download
    |> cast(attrs, [:token, :editorial_id, :photo_ids])
    |> validate_required([:token, :editorial_id, :photo_ids])
    |> unique_constraint(:token)
  end

  def encode_photo_ids(ids), do: Jason.encode!(ids)

  def decode_photo_ids(%__MODULE__{photo_ids: raw}) do
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
end
