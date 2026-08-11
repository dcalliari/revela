defmodule Revela.Capture.CardImport do
  @moduledoc """
  Importa fotos avulsas do cartao da camera (JPEG/RAW) para o editorial ativo.

  Copia os arquivos para a pasta do editorial (para o cartao poder ser ejetado),
  gera preview e cria o mesmo tipo de registro que a ingestao tethered. Sem
  editorial ativo, recusa — nunca escreve no limbo `_sem-editorial`.

  Reimportar o mesmo arquivo (mesmo conteudo) e idempotente via `source_hash`.
  """

  import Ecto.Query, warn: false

  alias Revela.Capture
  alias Revela.Capture.{Ingest, Photo}
  alias Revela.Repo

  @doc """
  Importa a pasta `source_dir` para o editorial ativo.

  Opcoes:
  - `:preview_fun` — `(src, dest) -> :ok | {:error, term}` (padrao: `Ingest.make_preview/2`)
  """
  def import_folder(source_dir, opts \\ [])

  def import_folder(source_dir, opts) when is_binary(source_dir) do
    source_dir = String.trim(source_dir)
    preview_fun = Keyword.get(opts, :preview_fun, &Ingest.make_preview/2)

    cond do
      source_dir == "" ->
        {:error, :empty_path}

      not File.dir?(source_dir) ->
        {:error, :not_a_directory}

      true ->
        case Capture.current_editorial() do
          nil ->
            {:error, :no_active_editorial}

          editorial ->
            do_import(editorial, Path.expand(source_dir), preview_fun)
        end
    end
  end

  defp do_import(editorial, source_dir, preview_fun) do
    File.mkdir_p!(editorial.folder)

    files = list_import_candidates(source_dir)

    {jpeg_paths, raw_paths} = Enum.split_with(files, &Ingest.jpeg?/1)

    {imported, skipped, errors, used_raws} =
      Enum.reduce(jpeg_paths, {0, 0, [], MapSet.new()}, fn jpeg, acc ->
        import_jpeg(jpeg, editorial, preview_fun, acc)
      end)

    {imported, skipped, errors, _used} =
      Enum.reduce(raw_paths, {imported, skipped, errors, used_raws}, fn raw, acc ->
        import_orphan_raw(raw, editorial, preview_fun, acc)
      end)

    {:ok, %{imported: imported, skipped: skipped, errors: Enum.reverse(errors)}}
  end

  # Arquivos na pasta selecionada e um nivel abaixo (ex.: DCIM → CAMFOLDER).
  defp list_import_candidates(source_dir) do
    direct = list_supported_files(source_dir)

    nested =
      source_dir
      |> File.ls!()
      |> Enum.map(&Path.join(source_dir, &1))
      |> Enum.filter(&File.dir?/1)
      |> Enum.flat_map(&list_supported_files/1)

    (direct ++ nested)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp list_supported_files(dir) do
    case File.ls(dir) do
      {:ok, names} ->
        names
        |> Enum.map(&Path.join(dir, &1))
        |> Enum.filter(&(File.regular?(&1) and Ingest.supported_photo?(&1)))

      {:error, _} ->
        []
    end
  end

  defp import_jpeg(jpeg_src, editorial, preview_fun, {imported, skipped, errors, used_raws}) do
    hash = content_hash(jpeg_src)
    filename = Path.basename(jpeg_src)

    if already_imported?(editorial.id, hash) do
      raw_src = Ingest.find_raw_sibling(jpeg_src)
      used_raws = if raw_src, do: MapSet.put(used_raws, Path.expand(raw_src)), else: used_raws
      {imported, skipped + 1, errors, used_raws}
    else
      raw_src = Ingest.find_raw_sibling(jpeg_src)

      with {:ok, jpeg_dest} <- copy_into_editorial(jpeg_src, editorial.folder),
           {:ok, raw_dest, used_raws} <- maybe_copy_raw(raw_src, editorial.folder, used_raws),
           {:ok, web_path} <- build_preview(jpeg_dest, preview_fun),
           {:ok, _photo} <-
             Capture.create_photo(%{
               web_path: web_path,
               original_path: jpeg_dest,
               raw_path: raw_dest,
               source_hash: hash,
               original_filename: filename,
               shot_at: file_mtime(jpeg_src)
             }) do
        {imported + 1, skipped, errors, used_raws}
      else
        {:error, %Ecto.Changeset{} = changeset} ->
          if source_hash_conflict?(changeset) do
            {imported, skipped + 1, errors, used_raws}
          else
            {imported, skipped, [{filename, changeset} | errors], used_raws}
          end

        {:error, reason} ->
          {imported, skipped, [{filename, reason} | errors], used_raws}
      end
    end
  end

  defp import_orphan_raw(raw_src, editorial, preview_fun, {imported, skipped, errors, used_raws}) do
    expanded = Path.expand(raw_src)

    if MapSet.member?(used_raws, expanded) do
      {imported, skipped, errors, used_raws}
    else
      hash = content_hash(raw_src)
      filename = Path.basename(raw_src)

      if already_imported?(editorial.id, hash) do
        {imported, skipped + 1, errors, used_raws}
      else
        with {:ok, raw_dest} <- copy_into_editorial(raw_src, editorial.folder),
             {:ok, web_path} <- build_preview(raw_dest, preview_fun),
             {:ok, _photo} <-
               Capture.create_photo(%{
                 web_path: web_path,
                 original_path: raw_dest,
                 raw_path: raw_dest,
                 source_hash: hash,
                 original_filename: filename,
                 shot_at: file_mtime(raw_src)
               }) do
          {imported + 1, skipped, errors, MapSet.put(used_raws, expanded)}
        else
          {:error, %Ecto.Changeset{} = changeset} ->
            if source_hash_conflict?(changeset) do
              {imported, skipped + 1, errors, used_raws}
            else
              {imported, skipped, [{filename, changeset} | errors], used_raws}
            end

          {:error, reason} ->
            {imported, skipped, [{filename, reason} | errors], used_raws}
        end
      end
    end
  end

  defp maybe_copy_raw(nil, _folder, used_raws), do: {:ok, nil, used_raws}

  defp maybe_copy_raw(raw_src, folder, used_raws) do
    case copy_into_editorial(raw_src, folder) do
      {:ok, dest} ->
        {:ok, dest, MapSet.put(used_raws, Path.expand(raw_src))}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp build_preview(dest_path, preview_fun) do
    stem = dest_path |> Path.basename() |> Path.rootname()
    {web_rel, web_path} = Ingest.preview_paths(stem)
    web_dest = Path.join(uploads_dir(), web_rel)

    case preview_fun.(dest_path, web_dest) do
      :ok -> {:ok, web_path}
      {:error, reason} -> {:error, reason}
    end
  end

  defp copy_into_editorial(src, folder) do
    dest = Path.join(folder, Path.basename(src))

    cond do
      Path.expand(src) == Path.expand(dest) ->
        {:ok, dest}

      File.exists?(dest) ->
        if same_content?(src, dest) do
          {:ok, dest}
        else
          alt = Path.join(folder, "import-#{short_hash(src)}-#{Path.basename(src)}")
          File.cp!(src, alt)
          {:ok, alt}
        end

      true ->
        File.cp!(src, dest)
        {:ok, dest}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  defp already_imported?(editorial_id, hash) do
    Repo.exists?(
      from p in Photo,
        where: p.editorial_id == ^editorial_id and p.source_hash == ^hash
    )
  end

  defp source_hash_conflict?(%Ecto.Changeset{} = changeset) do
    Enum.any?(changeset.errors, fn
      {:source_hash, _} -> true
      _ -> false
    end)
  end

  defp content_hash(path) do
    path
    |> File.stream!(64 * 1024, [])
    |> Enum.reduce(:crypto.hash_init(:sha256), fn chunk, acc ->
      :crypto.hash_update(acc, chunk)
    end)
    |> :crypto.hash_final()
    |> Base.encode16(case: :lower)
  end

  defp short_hash(path), do: path |> content_hash() |> String.slice(0, 8)

  defp same_content?(a, b), do: content_hash(a) == content_hash(b)

  defp file_mtime(path) do
    case File.stat(path) do
      {:ok, %{mtime: mtime}} ->
        mtime
        |> NaiveDateTime.from_erl!()
        |> DateTime.from_naive!("Etc/UTC")

      _ ->
        DateTime.utc_now()
    end
  end

  defp uploads_dir do
    Application.app_dir(:revela, "priv/static/uploads")
  end
end
