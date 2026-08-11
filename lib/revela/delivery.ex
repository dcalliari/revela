defmodule Revela.Delivery do
  @moduledoc """
  Entrega de selecoes para a marca / fotografo.

  MVP: URL local tokenizada (`LocalShare`) com grade de JPG/previews.
  Google Drive / Fotos ficam atras desta interface e retornam
  `{:error, :not_configured}` ate existirem credenciais — nao bloqueiam o ship.
  """

  alias Revela.Capture
  alias Revela.Capture.BrandShare
  alias Revela.Delivery.RawDownload
  alias Revela.Repo
  alias Revela.Delivery.{LocalShare, GoogleFotos, GoogleDrive}

  @type share_result :: {:ok, BrandShare.t(), String.t()} | {:error, term()}

  @doc """
  Cria um compartilhamento da selecao. `backend` padrao `:local`.
  Retorna `{:ok, share, url_path}` onde `url_path` e relativo (ex. `/share/abc`).
  """
  def create_brand_share(editorial_id, photo_ids, opts \\ []) do
    backend = Keyword.get(opts, :backend, :local)
    label = Keyword.get(opts, :label)

    case backend do
      :local -> LocalShare.create(editorial_id, photo_ids, label)
      :google_fotos -> GoogleFotos.create(editorial_id, photo_ids, label)
      :google_drive -> GoogleDrive.create(editorial_id, photo_ids, label)
      other -> {:error, {:unknown_backend, other}}
    end
  end

  @doc "Resolve um share pelo token (apenas backend local/persistido)."
  def get_brand_share(token), do: Capture.get_brand_share_by_token(token)

  @doc "Cria um token curto e persistido para uma selecao de RAW."
  def create_raw_download(editorial_id, photo_ids) when is_list(photo_ids) do
    %RawDownload{}
    |> RawDownload.changeset(%{
      token: Ecto.UUID.generate(),
      editorial_id: editorial_id,
      photo_ids: RawDownload.encode_photo_ids(photo_ids)
    })
    |> Repo.insert()
  end

  def get_raw_download(token), do: Repo.get_by(RawDownload, token: token)

  @doc """
  Prepara o pull de RAW da selecao. Retorna caminhos existentes e faltantes.
  Nao faz matching de siblings — usa so `photo.raw_path` preenchido.
  """
  def raw_pull(photo_ids) when is_list(photo_ids) do
    photos = Capture.get_photos(photo_ids)

    Enum.reduce(photos, %{files: [], missing: []}, fn photo, acc ->
      path = photo.raw_path

      cond do
        is_binary(path) and path != "" and File.regular?(path) ->
          %{acc | files: [%{photo: photo, path: path} | acc.files]}

        true ->
          %{acc | missing: [photo | acc.missing]}
      end
    end)
    |> then(fn %{files: files, missing: missing} ->
      %{files: Enum.reverse(files), missing: Enum.reverse(missing)}
    end)
  end
end
