defmodule Revela.Capture.Ingest do
  @moduledoc """
  Processa um arquivo recem baixado pelo gphoto2: gera um preview web a partir
  do JPEG (em `uploads/<editorial_id>/` ou `uploads/_sem-editorial/`) e registra
  a foto no editorial ativo. O RAW (.cr2/.cr3) irmao, quando existe, e associado
  para edicao posterior (ex: no darktable).

  Por padrao o JPEG da camera e apagado depois que o preview existe e o RAW
  irmao assentou. Defina `REVELA_KEEP_CAMERA_JPEG=1` ou
  `config :revela, :keep_camera_jpeg, true` para manter o JPEG.

  Em RAW+JPEG o gphoto2 nomeia com `%Y%m%d-%H%M%S-%03n.%C`: o JPEG leva o indice
  N e o RAW o N+1 (ex. `20260804-133708-027.jpg` / `20260804-133708-028.cr2`), e
  o carimbo do nome pode diferir ~1s porque o RAW demora mais a transferir.
  """

  require Logger

  alias Revela.Capture

  # maior lado do preview web, em pixels
  @preview_edge 1600
  @raw_exts ~w(.cr2 .cr3)
  @jpeg_exts ~w(.jpg .jpeg)
  # tolerancia no carimbo do nome (RAW pode sair 1s depois do JPEG)
  @timestamp_tolerance_seconds 2
  # gphoto2: YYYYMMDD-HHMMSS-NNN (indice tipicamente 3 digitos, mas aceita mais)
  @name_pattern ~r/^(\d{8})-(\d{6})-(\d+)$/

  @doc """
  Processa o JPEG em `path`. Ignora arquivos que nao sejam JPEG (`.cr2`/`.cr3`
  entram via `attach_raw/1` como irmao, nao por este caminho).
  """
  def process(path, opts \\ []) do
    if jpeg?(path) and File.exists?(path) do
      do_process(path, opts)
    else
      :ignore
    end
  end

  @doc """
  Retorna se o JPEG original deve ser mantido.
  """
  def keep_camera_jpeg? do
    Application.get_env(:revela, :keep_camera_jpeg, false) == true
  end

  defp do_process(path, opts) do
    stem = path |> Path.basename() |> Path.rootname()
    {web_rel, web_path} = preview_paths(stem)
    web_dest = Path.join(uploads_dir(), web_rel)

    case make_preview(path, web_dest) do
      :ok ->
        # So reivindica um RAW quando o chamador confirmou que ele assentou.
        # Se ainda chega, attach_raw/1 faz o claim na passada posterior.
        case Capture.create_photo(%{
               web_path: web_path,
               original_path: path,
               raw_path: nil,
               shot_at: DateTime.utc_now()
             }) do
          {:ok, photo} ->
            maybe_claim_raw_sibling(photo, path, Keyword.get(opts, :raw_settled, false))

          error ->
            error
        end

      {:error, reason} ->
        Logger.error("Falha ao gerar preview de #{path}: #{reason}")
        {:error, reason}
    end
  end

  defp maybe_claim_raw_sibling(photo, jpeg_path, raw_settled?) do
    case {raw_settled?, find_raw_sibling(jpeg_path)} do
      {true, raw_path} when is_binary(raw_path) ->
        case Capture.update_raw_path(photo, raw_path) do
          {:ok, updated} -> maybe_discard_after_raw(updated, jpeg_path, raw_path)
          {:error, reason} ->
            Logger.warning("ingest raw_path: falha ao gravar photo=#{photo.id}: #{inspect(reason)}")
            {:ok, photo}
        end

      _ ->
        {:ok, photo}
    end
  end

  defp maybe_discard_after_raw(photo, jpeg_path, _raw_path) do
    discard_camera_jpeg(photo, jpeg_path)
  end

  defp discard_camera_jpeg(photo, path) do
    cond do
      keep_camera_jpeg?() or not is_binary(path) -> {:ok, photo}
      true ->
        case File.rm(path) do
          :ok ->
            case Capture.clear_original_path(photo) do
              {:ok, updated} -> {:ok, updated}
              {:error, reason} ->
                Logger.warning("ingest original_path: falha ao limpar photo=#{photo.id}: #{inspect(reason)}")
                {:ok, photo}
            end
          {:error, reason} ->
            Logger.warning("Nao foi possivel apagar JPEG da camera #{path}: #{inspect(reason)}")
            {:ok, photo}
        end
    end
  end

  @doc false
  def preview_paths(stem) do
    scope = preview_scope()
    web_name = stem <> ".jpg"
    {Path.join(scope, web_name), "/uploads/#{scope}/#{web_name}"}
  end

  defp preview_scope do
    case Capture.current_editorial_id() do
      nil -> "_sem-editorial"
      id -> Integer.to_string(id)
    end
  end

  # Reduz o JPEG da camera para um preview web (so encolhe, nunca amplia).
  #
  # `jpeg:size` vem antes do arquivo de origem porque e uma dica de leitura: o
  # libjpeg decodifica direto numa escala DCT reduzida em vez de abrir os 17.9 MP
  # da T6 para so entao encolher. `-auto-orient` precisa continuar antes do
  # `-thumbnail`, que descarta o EXIF junto com a tag de orientacao.
  defp make_preview(src, dest) do
    File.mkdir_p!(Path.dirname(dest))

    case System.cmd(
           "magick",
           [
             "-define",
             "jpeg:size=#{@preview_edge}x#{@preview_edge}",
             src,
             "-auto-orient",
             "-thumbnail",
             "#{@preview_edge}x#{@preview_edge}>",
             "-quality",
             "82",
             "-sampling-factor",
             "4:2:0",
             "-strip",
             dest
           ],
           stderr_to_stdout: true
         ) do
      {_, 0} -> :ok
      {out, code} -> {:error, "magick saiu #{code}: #{String.slice(out, 0, 200)}"}
    end
  end

  @doc """
  Localiza o RAW irmao de um JPEG no mesmo diretorio.

  1. Match exato de basename (`foo.jpg` → `foo.cr2` / `.cr3`, case-insensitive).
  2. Fallback: RAW com indice `jpeg.index + 1` e carimbo de nome dentro de
     `#{@timestamp_tolerance_seconds}`s (padrao gphoto2 `%Y%m%d-%H%M%S-%03n`).

  Nomes fora do padrao nao casam no fallback (sem crash). RAWs ja associados a
  outra foto sao ignorados. Com varios candidatos (ex. `.cr2` e `.cr3`), prefere
  o mais proximo em tempo e registra ambiguidade.
  """
  def find_raw_sibling(jpeg_path, opts \\ []) when is_binary(jpeg_path) do
    taken = Keyword.get_lazy(opts, :taken, &Capture.claimed_raw_paths/0)

    case match_raw_sibling(jpeg_path, Keyword.put(opts, :taken, taken)) do
      {:ok, path} -> path
      :ambiguous -> nil
      :not_found -> nil
    end
  end

  @doc """
  Como `find_raw_sibling/2`, mas distingue ambiguidade.

  Opcoes:
  - `:taken` — `MapSet` de caminhos RAW ja usados
  - `:on_ambiguity` — `:prefer_closest` (ingest, default) ou `:skip` (backfill)
  """
  def match_raw_sibling(jpeg_path, opts \\ []) when is_binary(jpeg_path) do
    taken = Keyword.get(opts, :taken, MapSet.new())
    on_ambiguity = Keyword.get(opts, :on_ambiguity, :prefer_closest)

    cond do
      not File.exists?(jpeg_path) ->
        :not_found

      exact = exact_raw_sibling(jpeg_path, taken) ->
        {:ok, exact}

      true ->
        pick_adjacent_raw(jpeg_path, taken, on_ambiguity)
    end
  end

  @doc """
  Quando um RAW chega depois do JPEG (ordem tipica na transferencia), tenta
  associá-lo a uma foto do mesmo diretorio ainda sem `raw_path`.

  So casa basename exato ou par gphoto2 com `raw.index == jpeg.index + 1` e
  carimbo dentro da tolerancia. Com varios candidatos, prefere o mais proximo
  em tempo e registra ambiguidade (diferente do backfill, que pula).
  """
  def attach_raw(raw_path) when is_binary(raw_path) do
    if raw?(raw_path) and File.exists?(raw_path) do
      do_attach_raw(raw_path)
    else
      :ignore
    end
  end

  defp do_attach_raw(raw_path) do
    claimed = Capture.claimed_raw_paths()

    if MapSet.member?(claimed, raw_path) do
      :ignore
    else
      dir = Path.dirname(raw_path)

      candidates =
        Capture.list_photos_missing_raw(dir: dir)
        |> Enum.filter(fn photo ->
          is_binary(photo.original_path) and Path.dirname(photo.original_path) == dir and
            sibling_pair?(photo.original_path, raw_path)
        end)

      case rank_photos_for_raw(candidates, raw_path) do
        [] ->
          :ignore

        [photo] ->
          case Capture.update_raw_path(photo, raw_path) do
            {:ok, updated} -> maybe_discard_after_raw(updated, updated.original_path, raw_path)
            error -> error
          end

        [photo | rest] ->
          Logger.warning(
            "RAW sibling ambiguo para #{raw_path}: " <>
              "associando a #{photo.original_path} " <>
              "(outros: #{Enum.map_join(rest, ", ", & &1.original_path)})"
          )

          case Capture.update_raw_path(photo, raw_path) do
            {:ok, updated} -> maybe_discard_after_raw(updated, updated.original_path, raw_path)
            error -> error
          end
      end
    end
  end

  @doc false
  def sibling_pair?(jpeg_path, raw_path)
      when is_binary(jpeg_path) and is_binary(raw_path) do
    cond do
      Path.rootname(jpeg_path) == Path.rootname(raw_path) and raw?(raw_path) ->
        true

      true ->
        with {:ok, jpeg_meta} <- parse_capture_path(jpeg_path),
             {:ok, raw_meta} <- parse_capture_path(raw_path) do
          jpeg_to_raw_sibling?(jpeg_meta, raw_meta)
        else
          _ -> false
        end
    end
  end

  @doc """
  Percorre fotos com `raw_path` vazio e preenche matches unívocos no disco.
  Idempotente; nunca sobrescreve `raw_path` nao-vazio.

  Retorna `%{matched: n, ambiguous: n, not_found: n, claim_error: n, skipped_missing_file: n}`.
  """
  def backfill_raw_paths(opts \\ []) do
    dry_run? = Keyword.get(opts, :dry_run, false)
    taken = Capture.claimed_raw_paths()

    {summary, _taken} =
      Capture.list_photos_missing_raw()
      |> Enum.reduce({empty_backfill_summary(), taken}, fn photo, {summary, taken} ->
        backfill_one(photo, summary, taken, dry_run?)
      end)

    summary
  end

  defp backfill_one(photo, summary, taken, dry_run?) do
    jpeg = photo.original_path

    cond do
      not is_binary(jpeg) or jpeg == "" or not File.exists?(jpeg) ->
        {Map.update!(summary, :skipped_missing_file, &(&1 + 1)), taken}

      true ->
        case match_raw_sibling(jpeg, taken: taken, on_ambiguity: :skip) do
          {:ok, raw_path} ->
            cond do
              dry_run? ->
                {Map.update!(summary, :matched, &(&1 + 1)), MapSet.put(taken, raw_path)}

              true ->
                case Capture.update_raw_path(photo, raw_path) do
                  {:ok, _} ->
                    {Map.update!(summary, :matched, &(&1 + 1)), MapSet.put(taken, raw_path)}

                  {:error, reason} ->
                    Logger.warning(
                      "backfill raw_path: falha ao gravar photo=#{photo.id} raw=#{raw_path}: #{inspect(reason)}"
                    )

                    {Map.update!(summary, :claim_error, &(&1 + 1)), taken}
                end
            end

          :ambiguous ->
            Logger.warning(
              "backfill raw_path: ambiguidade para photo=#{photo.id} jpeg=#{jpeg}; pulando"
            )

            {Map.update!(summary, :ambiguous, &(&1 + 1)), taken}

          :not_found ->
            {Map.update!(summary, :not_found, &(&1 + 1)), taken}
        end
    end
  end

  defp empty_backfill_summary do
    %{matched: 0, ambiguous: 0, not_found: 0, claim_error: 0, skipped_missing_file: 0}
  end

  defp exact_raw_sibling(jpeg_path, taken) do
    base = Path.rootname(jpeg_path)

    @raw_exts
    |> Enum.flat_map(fn ext -> [base <> ext, base <> String.upcase(ext)] end)
    |> Enum.uniq()
    |> Enum.find(fn candidate ->
      File.exists?(candidate) and not MapSet.member?(taken, candidate)
    end)
  end

  defp pick_adjacent_raw(jpeg_path, taken, on_ambiguity) do
    with {:ok, jpeg_meta} <- parse_capture_path(jpeg_path),
         raws when raws != [] <- list_raw_metas(Path.dirname(jpeg_path), taken) do
      candidates =
        raws
        |> Enum.filter(&jpeg_to_raw_sibling?(jpeg_meta, &1))
        |> Enum.sort_by(&score_pair(jpeg_meta, &1))

      case {candidates, on_ambiguity} do
        {[], _} ->
          :not_found

        {[best], _} ->
          {:ok, best.path}

        {[best | rest], :prefer_closest} ->
          Logger.warning(
            "RAW sibling ambiguo para #{jpeg_path}: " <>
              "escolhendo #{best.path} " <>
              "(outros: #{Enum.map_join(rest, ", ", & &1.path)})"
          )

          {:ok, best.path}

        {[_ | _], :skip} ->
          :ambiguous
      end
    else
      :error -> :not_found
      [] -> :not_found
    end
  end

  defp list_raw_metas(dir, taken) do
    case File.ls(dir) do
      {:ok, entries} ->
        entries
        |> Enum.filter(&raw_filename?/1)
        |> Enum.map(&Path.join(dir, &1))
        |> Enum.reject(&MapSet.member?(taken, &1))
        |> Enum.flat_map(fn path ->
          case parse_capture_path(path) do
            {:ok, meta} -> [meta]
            :error -> []
          end
        end)

      {:error, _} ->
        []
    end
  end

  # Par documentado gphoto2: JPEG N com RAW N+1 (ingest e attach).
  defp jpeg_to_raw_sibling?(jpeg, raw) do
    raw.index == jpeg.index + 1 and within_timestamp_tolerance?(jpeg, raw)
  end

  defp within_timestamp_tolerance?(jpeg, raw) do
    abs(DateTime.diff(raw.datetime, jpeg.datetime, :second)) <= @timestamp_tolerance_seconds
  end

  # menor score = melhor: distancia de tempo (indice ja filtrado a N+1)
  defp score_pair(jpeg, raw) do
    time_dist = abs(DateTime.diff(raw.datetime, jpeg.datetime, :second))
    {time_dist, raw.path}
  end

  defp rank_photos_for_raw(photos, raw_path) do
    case parse_capture_path(raw_path) do
      :error ->
        photos

      {:ok, raw_meta} ->
        photos
        |> Enum.flat_map(fn photo ->
          case parse_capture_path(photo.original_path) do
            {:ok, jpeg_meta} -> [{photo, score_pair(jpeg_meta, raw_meta)}]
            :error -> []
          end
        end)
        |> Enum.sort_by(fn {_photo, score} -> score end)
        |> Enum.map(fn {photo, _} -> photo end)
    end
  end

  @doc false
  def parse_capture_path(path) when is_binary(path) do
    stem = path |> Path.basename() |> Path.rootname()

    case Regex.run(@name_pattern, stem) do
      [_, date, time, index] ->
        case parse_name_datetime(date, time) do
          {:ok, datetime} ->
            {:ok,
             %{
               path: path,
               stem: stem,
               index: String.to_integer(index),
               datetime: datetime
             }}

          :error ->
            :error
        end

      _ ->
        :error
    end
  end

  defp parse_name_datetime(
         <<y::binary-size(4), m::binary-size(2), d::binary-size(2)>>,
         <<hh::binary-size(2), mm::binary-size(2), ss::binary-size(2)>>
       ) do
    with {year, ""} <- Integer.parse(y),
         {month, ""} <- Integer.parse(m),
         {day, ""} <- Integer.parse(d),
         {hour, ""} <- Integer.parse(hh),
         {minute, ""} <- Integer.parse(mm),
         {second, ""} <- Integer.parse(ss),
         {:ok, date} <- Date.new(year, month, day),
         {:ok, time} <- Time.new(hour, minute, second),
         {:ok, datetime} <- DateTime.new(date, time, "Etc/UTC") do
      {:ok, datetime}
    else
      _ -> :error
    end
  end

  defp parse_name_datetime(_, _), do: :error

  defp jpeg?(path) do
    ext = path |> Path.extname() |> String.downcase()
    ext in @jpeg_exts
  end

  defp raw?(path) do
    ext = path |> Path.extname() |> String.downcase()
    ext in @raw_exts
  end

  defp raw_filename?(name) do
    ext = name |> Path.extname() |> String.downcase()
    ext in @raw_exts
  end

  defp uploads_dir do
    Application.app_dir(:revela, "priv/static/uploads")
  end
end
