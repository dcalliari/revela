defmodule Revela.Capture.Ingest do
  @moduledoc """
  Processa um arquivo recem baixado pelo gphoto2: gera um preview web a partir
  do JPEG e registra a foto. O RAW (.cr2) irmao, quando existe, e associado para
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
    web_name = stem <> ".jpg"
    web_dest = Path.join(uploads_dir(), web_name)

    case make_preview(path, web_dest) do
      :ok ->
        Capture.create_photo(%{
          web_path: "/uploads/" <> web_name,
          original_path: path,
          raw_path: find_raw_sibling(path),
          shot_at: DateTime.utc_now()
        })

      {:error, reason} ->
        Logger.error("Falha ao gerar preview de #{path}: #{reason}")
        {:error, reason}
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
    Application.get_env(
      :revela,
      :uploads_dir,
      Application.app_dir(:revela, "priv/static/uploads")
    )
  end
end
