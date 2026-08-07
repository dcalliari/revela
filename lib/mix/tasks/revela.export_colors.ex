defmodule Mix.Tasks.Revela.ExportColors do
  @shortdoc "Exporta fotos classificadas para pastas por cor"

  @moduledoc """
  Copia (padrao) ou move RAWs/JPEGs classificados para pastas nomeadas pela cor
  (`vermelho`, `amarelo`, `verde`, `azul`, `roxo`).

      mix revela.export_colors --dest /caminho/saida

  Opcoes:

      --dest PATH          Pasta raiz de destino (obrigatorio)
      --mode copy|move     Padrao: copy
      --reviewer ID        Revisor cujas labels definem a cor (padrao: host)
      --editorial ID       Editorial alvo (padrao: editorial ativo)
      --color LISTA        Cores a exportar, nomes ou numeros, separadas por virgula
                           (ex: vermelho,verde ou 0,2). Padrao: todas
      --ids LISTA          So estes photo ids (ex: 10,11,12)

  Prefere `raw_path`; se vazio/ausente, exporta o JPEG/preview e registra aviso.
  Google Drive/Fotos fica fora desta tarefa — ver README (entrega vs arquivo).
  """

  use Mix.Task

  @requirements ["app.start"]

  @folder_names Revela.Capture.Export.folder_names()

  @impl Mix.Task
  def run(args) do
    {opts, _rest, invalid} =
      OptionParser.parse(args,
        strict: [
          dest: :string,
          mode: :string,
          reviewer: :string,
          editorial: :integer,
          color: :string,
          ids: :string
        ]
      )

    if invalid != [] do
      Mix.raise("opcoes invalidas: #{inspect(invalid)}")
    end

    dest = Keyword.get(opts, :dest) || Mix.raise("--dest e obrigatorio")

    mode =
      case Keyword.get(opts, :mode, "copy") do
        "copy" -> :copy
        "move" -> :move
        other -> Mix.raise("--mode deve ser copy ou move (recebeu #{inspect(other)})")
      end

    export_opts =
      [
        dest: dest,
        mode: mode,
        reviewer_id: Keyword.get(opts, :reviewer, "host")
      ]
      |> maybe_put(:editorial_id, Keyword.get(opts, :editorial))
      |> maybe_put(:colors, parse_colors(Keyword.get(opts, :color)))
      |> maybe_put(:photo_ids, parse_ids(Keyword.get(opts, :ids)))

    case Revela.Capture.Export.export(export_opts) do
      {:ok, %{exported: exported, warnings: warnings, skipped: skipped}} ->
        Mix.shell().info("Exportados: #{length(exported)}")

        for e <- exported do
          Mix.shell().info("  [#{e.folder}] #{e.source} -> #{e.dest}")
        end

        if warnings != [] do
          Mix.shell().info("Avisos: #{length(warnings)}")

          for w <- warnings do
            Mix.shell().info("  ! #{w.message}")
          end
        end

        if skipped != [] do
          Mix.shell().info("Ignorados: #{length(skipped)}")

          for s <- skipped do
            Mix.shell().info("  - photo #{s.photo_id}: #{inspect(s.reason)}")
          end
        end

        :ok

      {:error, :no_active_editorial} ->
        Mix.raise("nenhum editorial ativo; passe --editorial ID")

      {:error, reason} ->
        Mix.raise("falha no export: #{inspect(reason)}")
    end
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  defp parse_colors(nil), do: nil

  defp parse_colors(str) do
    str
    |> String.split(",", trim: true)
    |> Enum.map(&parse_color_token/1)
  end

  defp parse_color_token(token) do
    token = String.trim(token) |> String.downcase()

    cond do
      match?({_, ""}, Integer.parse(token)) ->
        {n, ""} = Integer.parse(token)
        n

      true ->
        case Enum.find(@folder_names, fn {_k, name} -> name == token end) do
          {value, _} -> value
          nil -> Mix.raise("cor desconhecida: #{token}")
        end
    end
  end

  defp parse_ids(nil), do: nil

  defp parse_ids(str) do
    str
    |> String.split(",", trim: true)
    |> Enum.map(fn token ->
      case Integer.parse(String.trim(token)) do
        {n, ""} -> n
        _ -> Mix.raise("photo id invalido: #{token}")
      end
    end)
  end
end
