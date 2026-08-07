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
              {:ok, bin} ->
                name = "revela-raw-e#{editorial_id}.zip"

                conn
                |> put_resp_content_type("application/zip")
                |> put_resp_header("content-disposition", ~s(attachment; filename="#{name}"))
                |> send_resp(200, bin)

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
    entries =
      Enum.map(files, fn %{path: path} ->
        basename = path |> Path.basename() |> String.to_charlist()
        {basename, File.read!(path)}
      end)

    case :zip.create(~c"raws.zip", entries, [:memory]) do
      {:ok, {_, bin}} when is_binary(bin) -> {:ok, bin}
      other -> {:error, other}
    end
  end
end
