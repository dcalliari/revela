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
        requested_ids = photo_ids |> Enum.uniq() |> Enum.sort()
        photos = Capture.get_photos_in_editorial(editorial_id, requested_ids)

        photos = Enum.filter(photos, &(is_binary(&1.web_path) and &1.web_path != ""))

        if photos == [] do
          if Capture.get_photos_in_editorial(editorial_id, photo_ids) == [] do
            {:error, :empty_selection}
          else
            {:error, :no_previews}
          end
        else
          ids = Enum.map(photos, & &1.id)

          case reuse_matching_share(editorial_id, requested_ids, ids, label) do
            {:ok, share} ->
              {:ok, share, "/share/#{share.token}"}

            :new ->
              token = generate_token()

              case Capture.create_brand_share(%{
                     token: token,
                     editorial_id: editorial_id,
                     photo_ids: BrandShare.encode_photo_ids(ids),
                     requested_photo_ids: BrandShare.encode_photo_ids(requested_ids),
                     label: label
                   }) do
                {:ok, share} -> {:ok, share, "/share/#{share.token}"}
                error -> error
              end

            {:error, _} = error ->
              error
          end
        end
    end
  end

  defp reuse_matching_share(editorial_id, requested_ids, _ids, label) do
    wanted = MapSet.new(requested_ids)

    match =
      editorial_id
      |> Capture.list_brand_shares_for_editorial()
      |> List.first()
      |> case do
        nil -> nil
        share ->
          if MapSet.equal?(MapSet.new(decode_requested_ids(share)), wanted), do: share, else: nil
      end

    case match do
      nil ->
        :new

      share ->
        case Capture.touch_brand_share(share, label: label) do
          {:ok, touched} -> {:ok, touched}
          {:error, _} = error -> error
        end
    end
  end

  defp decode_requested_ids(%BrandShare{requested_photo_ids: raw}) when is_binary(raw) do
    case Jason.decode(raw) do
      {:ok, ids} when is_list(ids) -> ids
      _ -> []
    end
  end

  defp decode_requested_ids(_share), do: []

  defp generate_token do
    :crypto.strong_rand_bytes(12) |> Base.url_encode64(padding: false)
  end
end
