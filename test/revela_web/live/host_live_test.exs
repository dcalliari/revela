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

  test "mostra armando quando o auto-arm esta pendente" do
    document =
      render_capture_card(%{
        status: :idle,
        message: nil,
        camera_present: true,
        auto_arm_pending: true,
        editorial: "Casamento"
      })

    assert selected_count(document, "#capture-action[disabled]") == 1
    assert selected_text(document, "#capture-action") == "Armando tether…"
    assert selected_text(document, "#capture-status") == "armando"
    assert selected_text(document, "#capture-help") =~ "armando tether automaticamente"
  end

  test "prefere armando sobre espaco cheio enquanto o auto-arm esta pendente" do
    document =
      render_capture_card(%{
        status: :disk_full,
        message: "Espaço em disco abaixo do mínimo (~4.7 GB livres). Libere espaço.",
        camera_present: true,
        auto_arm_pending: true,
        editorial: "Casamento",
        disk_awareness: :available
      })

    assert selected_text(document, "#capture-action") == "Armando tether…"
    assert selected_text(document, "#capture-status") == "armando"
    assert selected_text(document, "#capture-help") =~ "armando tether automaticamente"
    refute selected_text(document, "#capture-help") =~ "Libere espaço"
  end

  test "mostra retomar apos stop explicito do operador" do
    document =
      render_capture_card(%{
        status: :idle,
        message: nil,
        camera_present: true,
        operator_stopped: true,
        editorial: "Casamento"
      })

    assert selected_text(document, "#capture-action") == "Retomar captura"
    assert selected_text(document, "#capture-help") =~ "Captura pausada"
  end

  test "explica auto-arm quando ha editorial e camera" do
    document =
      render_capture_card(%{
        status: :idle,
        message: nil,
        camera_present: true,
        editorial: "Casamento",
        disk_awareness: :available
      })

    assert selected_text(document, "#capture-help") =~ "arma automaticamente"
  end

  test "pede editorial antes de auto-armar no limbo" do
    document =
      render_capture_card(%{
        status: :idle,
        message: nil,
        camera_present: true,
        editorial: nil
      })

    assert selected_text(document, "#capture-help") =~ "Inicie um editorial"
  end

  test "explica vinculacao automatica quando armou sozinho" do
    document =
      render_capture_card(%{
        status: :running,
        message: nil,
        camera_present: true,
        armed_automatically: true
      })

    assert selected_text(document, "#capture-help") =~ "vinculada automaticamente"
  end

  test "avisa tether degradado quando a ingestao por pasta esta indisponivel" do
    document =
      render_capture_card(%{
        status: :running,
        message: nil,
        camera_present: true,
        armed_automatically: true,
        ingest_awareness: :unavailable
      })

    assert selected_text(document, "#capture-status") == "sem ingestão"
    assert selected_text(document, "#capture-help") =~ "ingestão por pasta indisponível"
    assert selected_text(document, "#capture-help") =~ "não entram na revisão"
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
        message:
          "Espaço em disco abaixo do mínimo (~4.7 GB livres). Libere espaço — " <>
            "o tether rearma automaticamente quando o espaço voltar.",
        camera_present: true
      })

    assert selected_text(document, "#capture-status") == "espaço cheio"
    assert selected_text(document, "#capture-help") =~ "rearma automaticamente"
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

  test "modo degradado de disco nao polui a captura card (aviso so no DevTools)" do
    document =
      render_capture_card(%{
        status: :idle,
        message: nil,
        camera_present: true,
        editorial: "Casamento",
        disk_awareness: :unavailable
      })

    assert selected_text(document, "#capture-help") =~ "monitoramento de disco indisponível"
    assert selected_text(document, "#capture-help") =~ "Vincule manualmente"
    assert selected_count(document, "#capture-disk-hint") == 0
  end

  test "demo armada mostra botao Disparar (demo)" do
    document =
      render_capture_card(%{
        status: :running,
        message: nil,
        camera_present: true,
        demo: true,
        editorial: nil
      })

    assert selected_count(document, "#demo-fire") == 1
    assert selected_text(document, "#demo-fire") == "Disparar (demo)"
    help = selected_text(document, "#capture-help")
    assert help =~ "botão"
    refute help =~ "tecla D"
  end

  test "demo armada com editorial menciona tecla D" do
    document =
      render_capture_card(%{
        status: :running,
        message: nil,
        camera_present: true,
        demo: true,
        editorial: "Sessão"
      })

    assert selected_count(document, "#demo-fire") == 1
    assert selected_text(document, "#capture-help") =~ "tecla D"
  end

  test "sem demo nao mostra botao Disparar" do
    document =
      render_capture_card(%{
        status: :running,
        message: nil,
        camera_present: true,
        demo: false
      })

    assert selected_count(document, "#demo-fire") == 0
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
