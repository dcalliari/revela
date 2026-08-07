defmodule Revela.Capture.Export do
  @moduledoc """
  Exporta fotos classificadas para pastas nomeadas pela cor (mesmo vocabulario
  do darktable / `RevelaWeb.Colors`: vermelho, amarelo, verde, azul, roxo).

  Prefere `raw_path` quando o arquivo existe; se estiver vazio ou ausente em
  disco, cai para o JPEG (`original_path`) e, em ultimo caso, o preview web,
  registrando aviso em ambos. Padrao: copiar (`:copy`); `:move` tambem e
  suportado para RAW/JPEG — preview web nunca e movido (quebraria a UI). Apos
  um `:move` bem-sucedido, `raw_path` / `original_path` no banco passam a
  apontar para o destino.

  Entrada tipica via `mix revela.export_colors` ou chamada direta daqui (a tela
  de pos-producao, item 11, pode reutilizar esta API sem bloquear este export).
  """

  require Logger
  import Ecto.Query, warn: false

  alias Revela.Repo
  alias Revela.Capture
  alias Revela.Capture.{Photo, Label}

  @folder_names %{
    0 => "vermelho",
    1 => "amarelo",
    2 => "verde",
    3 => "azul",
    4 => "roxo"
  }

  @doc "Nome da pasta de cor (0..4). Levanta se a cor for invalida."
  def folder_name(color) when is_integer(color) do
    Map.fetch!(@folder_names, color)
  end

  @doc "Mapa cor => nome de pasta."
  def folder_names, do: @folder_names

  @doc """
  Exporta fotos do editorial para `opts[:dest]`, agrupadas por pasta de cor.

  Opcoes:

    * `:dest` (obrigatorio) — pasta raiz de destino
    * `:mode` — `:copy` (padrao) ou `:move`
    * `:reviewer_id` — revisor cujas labels definem a cor (padrao `"host"`)
    * `:editorial_id` — editorial alvo (padrao: editorial ativo)
    * `:colors` — lista de inteiros `0..4` a exportar (padrao: todas)
    * `:photo_ids` — se informado, so esses ids (ainda respeitam `:colors`)
  """
  def export(opts) when is_list(opts) do
    dest = Keyword.fetch!(opts, :dest)
    mode = Keyword.get(opts, :mode, :copy)
    reviewer_id = Keyword.get(opts, :reviewer_id, "host")
    colors = Keyword.get(opts, :colors)
    photo_ids = Keyword.get(opts, :photo_ids)

    with :ok <- validate_mode(mode),
         {:ok, editorial_id} <- resolve_editorial_id(Keyword.get(opts, :editorial_id)),
         {:ok, color_filter} <- normalize_colors(colors),
         :ok <- ensure_dest(dest) do
      {photos, id_skips} = load_photos(editorial_id, photo_ids)
      labels = labels_for(editorial_id, reviewer_id)

      result =
        empty_result()
        |> prepend_skips(id_skips)
        |> then(fn acc ->
          Enum.reduce(photos, acc, fn photo, a ->
            export_one(photo, labels, color_filter, dest, mode, a)
          end)
        end)
        |> finalize_result()

      {:ok, result}
    end
  end

  defp finalize_result(result) do
    %{
      exported: Enum.reverse(result.exported),
      warnings: Enum.reverse(result.warnings),
      skipped: Enum.reverse(result.skipped)
    }
  end

  defp empty_result do
    %{exported: [], warnings: [], skipped: []}
  end

  defp prepend_skips(acc, skips) do
    Enum.reduce(skips, acc, fn entry, a ->
      Map.update!(a, :skipped, &[entry | &1])
    end)
  end

  defp validate_mode(mode) when mode in [:copy, :move], do: :ok
  defp validate_mode(mode), do: {:error, {:invalid_mode, mode}}

  defp resolve_editorial_id(nil) do
    case Capture.current_editorial_id() do
      nil -> {:error, :no_active_editorial}
      id -> {:ok, id}
    end
  end

  defp resolve_editorial_id(id) when is_integer(id), do: {:ok, id}

  defp ensure_dest(dest) do
    case File.mkdir_p(dest) do
      :ok -> :ok
      {:error, reason} -> {:error, {:mkdir_failed, dest, reason}}
    end
  end

  defp normalize_colors(nil), do: {:ok, MapSet.new(Map.keys(@folder_names))}

  defp normalize_colors([]) do
    {:error, {:invalid_colors, []}}
  end

  defp normalize_colors(colors) when is_list(colors) do
    invalid = Enum.reject(colors, &Map.has_key?(@folder_names, &1))

    if invalid == [] do
      {:ok, MapSet.new(colors)}
    else
      {:error, {:invalid_colors, invalid}}
    end
  end

  defp load_photos(editorial_id, nil) do
    photos =
      from(p in Photo,
        where: p.editorial_id == ^editorial_id,
        order_by: [asc: p.seq]
      )
      |> Repo.all()

    {photos, []}
  end

  defp load_photos(editorial_id, photo_ids) when is_list(photo_ids) do
    photos =
      from(p in Photo,
        where: p.editorial_id == ^editorial_id and p.id in ^photo_ids,
        order_by: [asc: p.seq]
      )
      |> Repo.all()

    loaded = MapSet.new(Enum.map(photos, & &1.id))

    skips =
      photo_ids
      |> Enum.uniq()
      |> Enum.reject(&MapSet.member?(loaded, &1))
      |> Enum.map(&skip_missing_photo(&1, editorial_id))

    {photos, skips}
  end

  defp skip_missing_photo(id, editorial_id) do
    case Repo.get(Photo, id) do
      nil ->
        %{photo_id: id, reason: :not_found}

      %Photo{editorial_id: other} when other != editorial_id ->
        %{photo_id: id, reason: {:wrong_editorial, other}}

      _photo ->
        %{photo_id: id, reason: :not_found}
    end
  end

  defp labels_for(editorial_id, reviewer_id) do
    from(l in Label,
      join: p in Photo,
      on: p.id == l.photo_id,
      where: p.editorial_id == ^editorial_id and l.reviewer_id == ^reviewer_id,
      select: {l.photo_id, l.color}
    )
    |> Repo.all()
    |> Map.new()
  end

  defp export_one(photo, labels, color_filter, dest_root, mode, acc) do
    case Map.get(labels, photo.id) do
      nil ->
        skip(acc, photo, :unlabeled)

      color ->
        if MapSet.member?(color_filter, color) do
          place(photo, color, dest_root, mode, acc)
        else
          skip(acc, photo, {:color_filtered, color})
        end
    end
  end

  defp place(photo, color, dest_root, mode, acc) do
    folder = folder_name(color)
    dest_dir = Path.join(dest_root, folder)

    case resolve_source(photo) do
      {:ok, _src, :preview, _warning} when mode == :move ->
        skip(acc, photo, :preview_move_refused)

      {:ok, src, kind, warning} ->
        File.mkdir_p!(dest_dir)
        dest = unique_dest(Path.join(dest_dir, Path.basename(src)))

        case transfer(mode, src, dest) do
          :ok ->
            case maybe_update_path_after_move(mode, photo, kind, dest) do
              :ok ->
                entry = %{
                  photo_id: photo.id,
                  color: color,
                  folder: folder,
                  source: src,
                  dest: dest,
                  mode: mode
                }

                acc
                |> Map.update!(:exported, &[entry | &1])
                |> maybe_warn(photo, warning)

              {:error, reason} ->
                skip(acc, photo, {:path_update_failed, reason, dest})
            end

          {:error, reason} ->
            skip(acc, photo, {:transfer_failed, reason, src, dest})
        end

      {:error, reason} ->
        skip(acc, photo, reason)
    end
  end

  defp resolve_source(%Photo{} = photo) do
    cond do
      usable?(photo.raw_path) ->
        {:ok, photo.raw_path, :raw, nil}

      usable?(photo.original_path) ->
        msg =
          "foto #{photo.id}: raw_path ausente ou inexistente; exportando JPEG #{photo.original_path}"

        {:ok, photo.original_path, :original, msg}

      usable?(preview = preview_abs(photo.web_path)) ->
        msg = "foto #{photo.id}: RAW e JPEG ausentes; exportando preview #{preview}"
        {:ok, preview, :preview, msg}

      true ->
        {:error, :no_source_file}
    end
  end

  defp usable?(path) when is_binary(path) and path != "", do: File.exists?(path)
  defp usable?(_), do: false

  defp preview_abs("/uploads/" <> rest) do
    Path.join(Application.app_dir(:revela, "priv/static/uploads"), rest)
  end

  defp preview_abs(_), do: nil

  defp unique_dest(path) do
    if File.exists?(path) do
      root = Path.rootname(path)
      ext = Path.extname(path)
      unique_dest_suffix(root, ext, 1)
    else
      path
    end
  end

  defp unique_dest_suffix(root, ext, n) do
    candidate = "#{root}-#{n}#{ext}"

    if File.exists?(candidate) do
      unique_dest_suffix(root, ext, n + 1)
    else
      candidate
    end
  end

  defp transfer(:copy, src, dest) do
    case File.cp(src, dest) do
      :ok -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp transfer(:move, src, dest) do
    case File.rename(src, dest) do
      :ok ->
        :ok

      {:error, :exdev} ->
        with :ok <- File.cp(src, dest),
             :ok <- File.rm(src) do
          :ok
        else
          {:error, reason} -> {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp maybe_update_path_after_move(:copy, _photo, _kind, _dest), do: :ok

  defp maybe_update_path_after_move(:move, photo, :raw, dest) do
    case photo |> Photo.changeset(%{raw_path: dest}) |> Repo.update() do
      {:ok, _} -> :ok
      {:error, changeset} -> {:error, changeset}
    end
  end

  defp maybe_update_path_after_move(:move, photo, :original, dest) do
    case photo |> Photo.changeset(%{original_path: dest}) |> Repo.update() do
      {:ok, _} -> :ok
      {:error, changeset} -> {:error, changeset}
    end
  end

  defp maybe_warn(acc, _photo, nil), do: acc

  defp maybe_warn(acc, photo, warning) do
    Logger.warning(warning)
    Map.update!(acc, :warnings, &[%{photo_id: photo.id, message: warning} | &1])
  end

  defp skip(acc, photo, reason) do
    Map.update!(acc, :skipped, &[%{photo_id: photo.id, reason: reason} | &1])
  end
end
