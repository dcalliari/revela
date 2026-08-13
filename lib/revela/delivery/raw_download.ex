defmodule Revela.Delivery.RawDownload do
  use Ecto.Schema
  import Ecto.Changeset

  def with_token_lock(token, fun) when is_binary(token) and is_function(fun, 0) do
    :global.trans(lock_id(token), fun)
  end

  def try_with_token_lock(token, fun) when is_binary(token) and is_function(fun, 0) do
    :global.trans(lock_id(token), fun, [node() | Node.list()], 0)
  end

  schema "raw_downloads" do
    field :token, :string
    field :photo_ids, :string
    field :expires_at, :utc_datetime_usec
    belongs_to :editorial, Revela.Capture.Editorial
    timestamps(type: :utc_datetime_usec)
  end

  def changeset(download, attrs) do
    download
    |> cast(attrs, [:token, :editorial_id, :photo_ids, :expires_at])
    |> validate_required([:token, :editorial_id, :photo_ids, :expires_at])
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

  defp lock_id(token), do: {{__MODULE__, token}, self()}
end
