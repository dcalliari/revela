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

  defp find_raw_sibling(path) do
    base = Path.rootname(path)

    [".cr2", ".CR2", ".cr3", ".CR3"]
    |> Enum.map(&(base <> &1))
    |> Enum.find(&File.exists?/1)
  end

  defp jpeg?(path) do
    ext = path |> Path.extname() |> String.downcase()
    ext in [".jpg", ".jpeg"]
  end

  defp uploads_dir do
    Application.app_dir(:revela, "priv/static/uploads")
  end
end
