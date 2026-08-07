defmodule RevelaWeb.HostLiveTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias RevelaWeb.HostLive

  test "orienta a conectar a camera quando ela esta ausente" do
    document = render_capture_card(%{status: :idle, message: nil, camera_present: false})

    assert selected_count(document, "#capture-card") == 1
    assert selected_count(document, "#capture-action[disabled]") == 1
    assert selected_text(document, "#capture-action") == "Conecte a câmera"
    assert selected_text(document, "#capture-status") == "desconectada"
    assert selected_text(document, "#capture-help") =~ "conecte o cabo USB"
  end

  test "oferece vincular uma camera detectada" do
    document = render_capture_card(%{status: :idle, message: nil, camera_present: true})

    assert selected_count(document, "#capture-action:not([disabled])") == 1
    assert selected_text(document, "#capture-action") == "Vincular câmera"
    assert selected_text(document, "#capture-status") == "detectada"
  end

  test "explica a retomada automatica depois de uma desconexao" do
    document =
      render_capture_card(%{
        status: :waiting_camera,
        message: "Camera desconectada.",
        camera_present: false
      })

    assert selected_text(document, "#capture-action") == "Cancelar reconexão"
    assert selected_text(document, "#capture-status") == "desconectada"
    assert selected_text(document, "#capture-help") =~ "retomar automaticamente"
  end

  test "explica a parada preventiva por espaco em disco" do
    document =
      render_capture_card(%{
        status: :disk_full,
        message: "Espaço em disco abaixo do mínimo (~4.7 GB livres). Libere espaço.",
        camera_present: true
      })

    assert selected_text(document, "#capture-status") == "espaço cheio"
    assert selected_text(document, "#capture-help") =~ "Libere espaço"
    assert selected_text(document, "#capture-action") == "Vincular câmera"
  end

  test "mostra quantas fotos ainda cabem quando a estimativa esta disponivel" do
    document =
      render_capture_card(%{
        status: :running,
        message: nil,
        camera_present: true,
        estimated_shots_left: 250
      })

    assert selected_text(document, "#capture-disk-hint") =~ "cabem ~250 fotos"
  end

  test "nao mostra a dica de espaco quando a estimativa e desconhecida" do
    document = render_capture_card(%{status: :idle, message: nil, camera_present: false})

    assert selected_count(document, "#capture-disk-hint") == 0
  end

  test "avisa modo degradado quando o monitoramento de disco esta indisponivel" do
    document =
      render_capture_card(%{
        status: :idle,
        message: nil,
        camera_present: true,
        disk_awareness: :unavailable
      })

    assert selected_text(document, "#capture-disk-hint") =~ "monitoramento de disco indisponível"
    assert selected_text(document, "#capture-disk-hint") =~ "Parada preventiva desativada"
  end

  defp render_capture_card(capture) do
    html = render_component(&HostLive.capture_card/1, capture: capture)
    LazyHTML.from_fragment(html)
  end

  defp selected_count(document, selector),
    do: document |> LazyHTML.query(selector) |> Enum.count()

  defp selected_text(document, selector) do
    document
    |> LazyHTML.query(selector)
    |> LazyHTML.text()
    |> String.trim()
  end
end
