defmodule Mix.Tasks.Revela.BackfillRawPaths do
  @shortdoc "Backfill empty photo raw_path from on-disk RAW siblings"

  @moduledoc """
  Percorre fotos com `raw_path` nulo/vazio e associa o RAW irmao no diretorio
  de `original_path`, usando a mesma logica de `Revela.Capture.Ingest`
  (`on_ambiguity: :skip`).

  Nao sobrescreve `raw_path` ja preenchido. Ambiguidade e falha de claim
  (RAW ja tomado por outra foto) sao puladas com log; o resumo inclui
  `matched`, `ambiguous`, `not_found`, `claim_error` e `skipped_missing_file`.

      mix revela.backfill_raw_paths
      mix revela.backfill_raw_paths --dry-run
  """

  use Mix.Task

  @switches [dry_run: :boolean]

  @impl Mix.Task
  def run(args) do
    {opts, _} = OptionParser.parse!(args, strict: @switches)
    dry_run? = Keyword.get(opts, :dry_run, false)

    Mix.Task.run("app.start")

    summary = Revela.Capture.Ingest.backfill_raw_paths(dry_run: dry_run?)

    prefix = if dry_run?, do: "[dry-run] ", else: ""

    Mix.shell().info(
      "#{prefix}backfill raw_path: matched=#{summary.matched} " <>
        "ambiguous=#{summary.ambiguous} not_found=#{summary.not_found} " <>
        "claim_error=#{summary.claim_error} " <>
        "skipped_missing_file=#{summary.skipped_missing_file}"
    )
  end
end
