defmodule Revela.Capture.IngestTest do
  use Revela.DataCase, async: true

  alias Revela.Capture
  alias Revela.Capture.Ingest

  test "preview paths ficam no limbo sem editorial ativo" do
    assert Ingest.preview_paths("IMG_001") ==
             {"_sem-editorial/IMG_001.jpg", "/uploads/_sem-editorial/IMG_001.jpg"}
  end

  test "preview paths sao namespaced pelo editorial ativo" do
    {:ok, editorial} = Capture.start_editorial("Casamento", "/tmp/casamento")
    id = Integer.to_string(editorial.id)

    assert Ingest.preview_paths("20260805-120000-001") ==
             {"#{id}/20260805-120000-001.jpg", "/uploads/#{id}/20260805-120000-001.jpg"}

    Capture.finish_editorial()

    assert Ingest.preview_paths("20260805-120000-001") ==
             {"_sem-editorial/20260805-120000-001.jpg",
              "/uploads/_sem-editorial/20260805-120000-001.jpg"}
  end

  test "editoriais distintos nao compartilham o mesmo caminho de preview" do
    {:ok, a} = Capture.start_editorial("A", "/tmp/a")
    path_a = Ingest.preview_paths("same-stem")

    {:ok, b} = Capture.start_editorial("B", "/tmp/b")
    path_b = Ingest.preview_paths("same-stem")

    refute path_a == path_b
    assert elem(path_a, 1) == "/uploads/#{a.id}/same-stem.jpg"
    assert elem(path_b, 1) == "/uploads/#{b.id}/same-stem.jpg"
  end
end
