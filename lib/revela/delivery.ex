defmodule Revela.Delivery do
  @moduledoc """
  Entrega de selecoes para a marca / fotografo.

  MVP: URL local tokenizada (`LocalShare`) com grade de JPG/previews.
  Google Drive / Fotos ficam atras desta interface e retornam
  `{:error, :not_configured}` ate existirem credenciais — nao bloqueiam o ship.
  """

  import Ecto.Query

  alias Revela.Capture
  alias Revela.Capture.Photo
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
  @raw_download_ttl 3600

  def create_raw_download(editorial_id, photo_ids) when is_list(photo_ids) do
    cleanup_expired_raw_downloads()

    %RawDownload{}
    |> RawDownload.changeset(%{
      token: Ecto.UUID.generate(),
      editorial_id: editorial_id,
      photo_ids: RawDownload.encode_photo_ids(photo_ids),
      expires_at: DateTime.add(DateTime.utc_now(), @raw_download_ttl, :second)
    })
    |> Repo.insert()
  end

  def get_raw_download(token) do
    case Repo.get_by(RawDownload, token: token) do
      %RawDownload{expires_at: %DateTime{} = expires_at} = download ->
        if DateTime.compare(expires_at, DateTime.utc_now()) == :gt, do: download, else: nil

      %RawDownload{} ->
        nil

      nil ->
        nil
    end
  end

  defp cleanup_expired_raw_downloads do
    from(d in RawDownload,
      where: not is_nil(d.expires_at) and d.expires_at <= ^DateTime.utc_now()
    )
    |> Repo.delete_all()

    sweep_stale_raw_archives()
  end

  defp sweep_stale_raw_archives do
    cutoff = DateTime.add(DateTime.utc_now(), -@raw_download_ttl, :second)

    raw_archive_roots()
    |> Enum.each(fn root ->
      case File.ls(root) do
        {:ok, entries} ->
          Enum.each(entries, fn entry ->
            sweep_stale_raw_artifact(root, entry, cutoff)
          end)

        {:error, _} ->
          :ok
      end
    end)
  end

  defp sweep_stale_raw_artifact(root, entry, cutoff) do
    with true <- String.starts_with?(entry, "revela-raw-"),
         token when token != "" <- raw_artifact_token(entry) do
      RawDownload.try_with_token_lock(token, fn ->
        path = Path.join(root, entry)

        with {:ok, stat} <- File.lstat(path, time: :posix),
             true <- stale_raw_artifact?(entry, stat.type),
             true <- stat.mtime < DateTime.to_unix(cutoff) do
          remove_raw_artifact(path, stat.type)
        end
      end)
    end
  end

  defp raw_artifact_token(entry) do
    token = String.replace_prefix(entry, "revela-raw-", "")

    cond do
      String.ends_with?(token, ".zip.tmp") -> String.trim_trailing(token, ".zip.tmp")
      String.ends_with?(token, ".zip") -> String.trim_trailing(token, ".zip")
      true -> token
    end
  end

  defp stale_raw_artifact?(entry, :regular),
    do: String.ends_with?(entry, ".zip") or String.ends_with?(entry, ".zip.tmp")

  defp stale_raw_artifact?(entry, :directory),
    do: not String.ends_with?(entry, ".zip") and not String.ends_with?(entry, ".zip.tmp")

  defp stale_raw_artifact?(_entry, _type), do: false

  defp remove_raw_artifact(path, :directory), do: File.rm_rf(path)
  defp remove_raw_artifact(path, :regular), do: File.rm(path)

  defp raw_archive_roots do
    editorials =
      Application.get_env(:revela, :editorials_dir) ||
        Path.join(File.cwd!(), "editorials")

    raw_photo_roots =
      from(p in Photo, where: not is_nil(p.raw_path) and p.raw_path != "", select: p.raw_path)
      |> Repo.all()
      |> Enum.map(&Path.join(Path.dirname(Path.expand(&1)), ".raw-pulls"))

    editorial_roots = Path.wildcard(Path.join(editorials, "**/.raw-pulls"))

    [Path.join(editorials, ".raw-pulls"), "/var/tmp" | raw_photo_roots ++ editorial_roots]
    |> Enum.uniq()
  end

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
