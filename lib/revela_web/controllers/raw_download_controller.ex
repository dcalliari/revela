defmodule RevelaWeb.RawDownloadController do
  @moduledoc """
  Download de RAW da selecao (pos-producao). Usa token assinado com os ids;
  so inclui arquivos com `raw_path` presente e legivel em disco.
  """
  use RevelaWeb, :controller

  alias Revela.Delivery

  @salt "raw-pull"
  @max_age 3600

  def create_token(editorial_id, photo_ids) when is_list(photo_ids) do
    Phoenix.Token.sign(
      RevelaWeb.Endpoint,
      @salt,
      %{editorial_id: editorial_id, photo_ids: photo_ids},
      max_age: @max_age
    )
  end

  def download(conn, %{"token" => token}) do
    case Phoenix.Token.verify(RevelaWeb.Endpoint, @salt, token, max_age: @max_age) do
      {:ok, %{editorial_id: editorial_id, photo_ids: photo_ids}} ->
        pull = Delivery.raw_pull(photo_ids)

        cond do
          pull.files == [] ->
            conn
            |> put_status(:unprocessable_entity)
            |> put_resp_content_type("text/plain")
            |> send_resp(
              422,
              missing_message(pull.missing)
            )

          true ->
            case build_zip(pull.files) do
              {:ok, zip_path} ->
                name = "revela-raw-e#{editorial_id}.zip"

                conn =
                  conn
                  |> put_resp_content_type("application/zip")
                  |> put_resp_header("content-disposition", ~s(attachment; filename="#{name}"))
                  |> send_file(200, zip_path)

                _ = File.rm(zip_path)
                conn

              {:error, reason} ->
                conn
                |> put_status(:internal_server_error)
                |> put_resp_content_type("text/plain")
                |> send_resp(500, "Falha ao montar o zip: #{inspect(reason)}")
            end
        end

      {:error, _} ->
        conn
        |> put_status(:forbidden)
        |> put_resp_content_type("text/plain")
        |> send_resp(403, "Link de download invalido ou expirado.")
    end
  end

  defp missing_message([]),
    do: "Nenhum RAW disponivel: raw_path vazio ou arquivo ausente em todas as fotos selecionadas."

  defp missing_message(missing) do
    names =
      missing
      |> Enum.take(8)
      |> Enum.map(fn p -> Path.basename(p.web_path || "foto-#{p.id}") end)
      |> Enum.join(", ")

    "Nenhum RAW disponivel para download. " <>
      "raw_path vazio ou arquivo ausente (ex.: #{names}). " <>
      "O casamento JPEG↔RAW (item 8) precisa preencher raw_path."
  end

  defp build_zip(files) do
    id = System.unique_integer([:positive])
    work_dir = Path.join(System.tmp_dir!(), "revela-raw-#{id}")
    zip_path = Path.join(System.tmp_dir!(), "revela-raw-#{id}.zip")

    try do
      with :ok <- File.mkdir_p(work_dir),
           :ok <- stage_files(files, work_dir),
           {:ok, _} <- create_zip_file(work_dir, zip_path) do
        {:ok, zip_path}
      else
        {:error, _} = err ->
          _ = File.rm(zip_path)
          err

        other ->
          _ = File.rm(zip_path)
          {:error, other}
      end
    after
      File.rm_rf(work_dir)
    end
  end

  defp stage_files(files, work_dir) do
    Enum.reduce_while(files, :ok, fn %{photo: photo, path: path}, :ok ->
      dest = Path.join(work_dir, zip_entry_name(photo, path))

      case link_or_copy(path, dest) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp zip_entry_name(photo, path) do
    "#{photo.seq}-#{Path.basename(path)}"
  end

  defp link_or_copy(src, dest) do
    case File.ln(src, dest) do
      :ok -> :ok
      {:error, _} -> File.cp(src, dest)
    end
  end

  defp create_zip_file(work_dir, zip_path) do
    names =
      work_dir
      |> File.ls!()
      |> Enum.map(&String.to_charlist/1)

    cwd = File.cwd!()

    try do
      File.cd!(work_dir)

      case :zip.create(String.to_charlist(zip_path), names) do
        {:ok, zip} -> {:ok, List.to_string(zip)}
        other -> {:error, other}
      end
    after
      File.cd!(cwd)
    end
  end
end
