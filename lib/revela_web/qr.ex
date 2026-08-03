defmodule RevelaWeb.QR do
  @moduledoc """
  Renderiza o QR como SVG na linguagem visual do site: marcadores de deteccao
  com cantos arredondados, modulos de dados em bolinhas e algumas delas nas
  cores dos classificadores.

  Estilizar um QR custa robustez, entao os parametros abaixo foram escolhidos
  medindo a taxa de decodificacao (OpenCV, 7 cenarios: original, desfoque,
  reducao, ruido e perspectiva). O QR quadrado da lib serve de referencia.

  O que a medicao mostrou:

    * bolinhas no lugar dos quadrados nao custam nada (6/7, igual a referencia);
    * arredondar os marcadores de deteccao e o que destroi a leitura: `rx` 1.0
      caiu para 2/7 e `rx` 2.1 para 0/7. Ate `rx` 0.25 se mantem em 6/7, entao
      eles ficam com um arredondamento minimo -- na pratica os marcadores
      precisam continuar quadrados, porque o leitor mede a razao 1:1:3:1:1 neles;
    * as cores dos classificadores, tais como aparecem na interface, se mantem
      em 6/7 na densidade de 1 em 9. Densidades maiores comecam a oscilar.

  Usa ainda correcao de erro `:q` (recupera ~25% dos modulos) no lugar do `:l`
  (~7%) padrao da lib, o que da folga para a estilizacao.

  A matriz do EQRCode ja vem com a zona de silencio embutida, e ela entra no
  viewBox: o SVG carrega a propria margem, sem depender de padding no CSS.
  """

  alias RevelaWeb.Colors

  # 1 em cada N bolinhas recebe cor; o resto fica no tom neutro
  @color_every 9

  # raio das bolinhas e arredondamento dos marcadores, em modulos
  @dot_r 0.5
  @eye_rx 0.25

  @doc """
  SVG do QR para `url`. Opcoes:

    * `:class` - classes CSS no elemento `svg`
    * `:hole` - cor do miolo claro dos marcadores (o da placa atras). Padrao "#fff"
  """
  def svg(url, opts \\ []) do
    class = Keyword.get(opts, :class, "")
    hole = Keyword.get(opts, :hole, "#fff")
    dot_r = Keyword.get(opts, :dot_r, @dot_r)
    eye_rx = Keyword.get(opts, :eye_rx, @eye_rx)
    palette = Keyword.get(opts, :palette, Enum.map(Colors.all(), & &1.hex))
    color_every = Keyword.get(opts, :color_every, @color_every)

    matrix = url |> EQRCode.encode(:q) |> rows()
    n = length(matrix)
    qz = quiet_zone(matrix)
    finders = [{qz, qz}, {qz, n - qz - 7}, {n - qz - 7, qz}]

    body =
      Enum.map_join(finders, "\n", &finder(&1, hole, eye_rx)) <>
        "\n" <> dots(matrix, finders, dot_r, palette, color_every)

    """
    <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 #{n} #{n}" class="#{class}">
    #{body}
    </svg>
    """
  end

  defp rows(%EQRCode.Matrix{matrix: matrix}) do
    matrix |> Tuple.to_list() |> Enum.map(&Tuple.to_list/1)
  end

  # a zona de silencio sao as linhas vazias do topo
  defp quiet_zone(matrix) do
    matrix
    |> Enum.take_while(fn row -> Enum.all?(row, &(&1 in [0, nil])) end)
    |> length()
  end

  # marcador: anel externo, miolo claro e nucleo. A razao 7:5:3 do padrao e
  # preservada, que e o que o leitor mede ao procurar os marcadores.
  defp finder({r, c}, hole, rx) do
    """
    <rect x="#{c}" y="#{r}" width="7" height="7" rx="#{rx}" fill="currentColor"/>
    <rect x="#{c + 1}" y="#{r + 1}" width="5" height="5" rx="#{rx * 0.7}" fill="#{hole}"/>
    <rect x="#{c + 2}" y="#{r + 2}" width="3" height="3" rx="#{rx * 0.45}" fill="currentColor"/>
    """
  end

  defp dots(matrix, finders, dot_r, palette, color_every) do
    matrix
    |> Enum.with_index()
    |> Enum.flat_map(fn {row, r} ->
      row
      |> Enum.with_index()
      |> Enum.filter(fn {v, c} -> v == 1 and not in_finder?(r, c, finders) end)
      |> Enum.map(fn {_, c} -> dot(r, c, dot_r, palette, color_every) end)
    end)
    |> Enum.join("\n")
  end

  defp dot(r, c, dot_r, palette, color_every) do
    fill =
      if color_every > 0 and rem(r * 7 + c * 13, color_every) == 0 do
        Enum.at(palette, rem(r + c, length(palette)))
      else
        "currentColor"
      end

    ~s(<circle cx="#{c + 0.5}" cy="#{r + 0.5}" r="#{dot_r}" fill="#{fill}"/>)
  end

  defp in_finder?(r, c, finders) do
    Enum.any?(finders, fn {fr, fc} ->
      r >= fr and r <= fr + 6 and c >= fc and c <= fc + 6
    end)
  end
end
