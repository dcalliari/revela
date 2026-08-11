defmodule Revela.Delivery.LocalShare do
  @moduledoc """
  Backend local: persiste `BrandShare` e expoe `/share/:token` com JPGs.
  """

  alias Revela.Capture
  alias Revela.Capture.BrandShare

  @doc "Cria share local. Retorna `{:ok, share, \"/share/\" <> token}`."
  def create(editorial_id, photo_ids, label \\ nil)

  def create(_editorial_id, [], _label), do: {:error, :empty_selection}

  def create(editorial_id, photo_ids, label) when is_list(photo_ids) do
    case Capture.get_editorial(editorial_id) do
      nil ->
        {:error, :editorial_not_found}

      _editorial ->
        photos = Capture.get_photos_in_editorial(editorial_id, photo_ids)

        if photos == [] do
          {:error, :empty_selection}
        else
          ids = Enum.map(photos, & &1.id)

          case reuse_matching_share(editorial_id, ids) do
            {:ok, share} ->
              {:ok, share, "/share/#{share.token}"}

            :new ->
              token = generate_token()

              case Capture.create_brand_share(%{
                     token: token,
                     editorial_id: editorial_id,
                     photo_ids: BrandShare.encode_photo_ids(ids),
                     label: label
                   }) do
                {:ok, share} -> {:ok, share, "/share/#{share.token}"}
                error -> error
              end
          end
        end
    end
  end

  defp reuse_matching_share(editorial_id, ids) do
    wanted = MapSet.new(ids)

    case Capture.list_brand_shares_for_editorial(editorial_id) do
      [latest | _] ->
        existing = MapSet.new(BrandShare.decode_photo_ids(latest))

        if MapSet.equal?(existing, wanted) do
          {:ok, latest}
        else
          :new
        end

      [] ->
        :new
    end
  end

  defp generate_token do
    :crypto.strong_rand_bytes(12) |> Base.url_encode64(padding: false)
  end
end
