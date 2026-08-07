defmodule Revela.Capture.Ingest do
  @moduledoc """
  Processa um arquivo recem baixado pelo gphoto2: gera um preview web a partir
  do JPEG (em `uploads/<editorial_id>/` ou `uploads/_sem-editorial/`) e registra
  a foto no editorial ativo. O RAW (.cr2) irmao, quando existe, e associado para
  edicao posterior (ex: no darktable).
  """

  require Logger
  alias Revela.Capture

  # maior lado do preview web, em pixels
  @preview_edge 1600

  @raw_exts ~w(.cr2 .CR2 .cr3 .CR3)

  @doc """
  Processa o JPEG em `path`. Ignora arquivos que nao sejam JPEG (o .cr2 e
  captado como irmao do JPEG, nao processado direto).
  """
  def process(path) do
    if jpeg?(path) and File.exists?(path) do
      do_process(path)
    else
      :ignore
    end
  end

  defp do_process(path) do
    stem = path |> Path.basename() |> Path.rootname()
    {web_rel, web_path} = preview_paths(stem)
    web_dest = Path.join(uploads_dir(), web_rel)

    case make_preview(path, web_dest) do
      :ok ->
        Capture.create_photo(%{
          web_path: web_path,
          original_path: path,
          raw_path: find_raw_sibling(path),
          shot_at: DateTime.utc_now()
        })

      {:error, reason} ->
        Logger.error("Falha ao gerar preview de #{path}: #{reason}")
        {:error, reason}
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

  @doc """
  Reduz a imagem de origem (JPEG ou RAW legivel pelo ImageMagick) para um
  preview web. So encolhe, nunca amplia.
  """
  def make_preview(src, dest) do
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
  Localiza o RAW irmao de um JPEG (ou outro path) no mesmo diretorio.

  1. Mesmo stem (`foto.jpg` → `foto.cr2`)
  2. Indice adjacente no sufixo numerico (RAW+JPEG tethered: `…-027.jpg` ↔
     `…-028.cr2`), porque a camera grava indices sequenciais distintos.
  """
  def find_raw_sibling(path) do
    dir = Path.dirname(path)
    stem = path |> Path.basename() |> Path.rootname()

    find_raw_with_stem(dir, stem) || find_adjacent_raw(dir, stem)
  end

  defp find_raw_with_stem(dir, stem) do
    @raw_exts
    |> Enum.map(&Path.join(dir, stem <> &1))
    |> Enum.find(&File.exists?/1)
  end

  defp find_adjacent_raw(dir, stem) do
    case Regex.run(~r/^(.*?)(\d+)$/, stem) do
      [_, prefix, digits] ->
        n = String.to_integer(digits)
        width = String.length(digits)

        Enum.find_value([n + 1, n - 1], fn adj ->
          adj_stem = prefix <> String.pad_leading(Integer.to_string(adj), width, "0")
          find_raw_with_stem(dir, adj_stem)
        end)

      _ ->
        nil
    end
  end

  @doc false
  def jpeg?(path) do
    ext = path |> Path.extname() |> String.downcase()
    ext in [".jpg", ".jpeg"]
  end

  @doc false
  def raw?(path) do
    ext = path |> Path.extname() |> String.downcase()
    ext in [".cr2", ".cr3"]
  end

  @doc false
  def supported_photo?(path), do: jpeg?(path) or raw?(path)

  defp uploads_dir do
    Application.app_dir(:revela, "priv/static/uploads")
  end
end
