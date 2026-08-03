defmodule RevelaWeb.Colors do
  @moduledoc """
  As 5 cores de classificacao, no mesmo mapeamento do darktable
  (0=vermelho 1=amarelo 2=verde 3=azul 4=roxo).
  """

  @colors [
    %{value: 0, name: "vermelho", hex: "#e11d48"},
    %{value: 1, name: "amarelo", hex: "#eab308"},
    %{value: 2, name: "verde", hex: "#22c55e"},
    %{value: 3, name: "azul", hex: "#3b82f6"},
    %{value: 4, name: "roxo", hex: "#a855f7"}
  ]

  def all, do: @colors

  def hex(value) do
    case Enum.find(@colors, &(&1.value == value)) do
      %{hex: hex} -> hex
      _ -> "#94a3b8"
    end
  end

  def name(value) do
    case Enum.find(@colors, &(&1.value == value)) do
      %{name: name} -> name
      _ -> "?"
    end
  end
end
