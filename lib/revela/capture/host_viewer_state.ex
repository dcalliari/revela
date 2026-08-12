defmodule Revela.Capture.HostViewerState do
  @moduledoc """
  Guarda o ultimo estado do visualizador do Host (slot unico, nao por
  conexao) para `/tv`. Um `Agent` em vez de `:persistent_term`: esse slot
  muda a cada navegacao do Host, e `:persistent_term` dispara GC global a
  cada escrita — adequado para dados raros, nao para esse volume de churn.
  """

  use Agent

  @default %{photo_id: nil, follow: true, open: false}

  def start_link(_opts) do
    Agent.start_link(fn -> @default end, name: __MODULE__)
  end

  def default, do: @default

  def get do
    Agent.get(__MODULE__, & &1)
  end

  def put(state) do
    Agent.update(__MODULE__, fn _ -> state end)
  end

  def reset do
    put(@default)
  end
end
