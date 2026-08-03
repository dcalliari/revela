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
