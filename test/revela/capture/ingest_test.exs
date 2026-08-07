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

  test "find_raw_sibling encontra stem exato e indice adjacente" do
    dir = Path.join(System.tmp_dir!(), "revela-sibling-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)

    jpeg = Path.join(dir, "IMG_100.JPG")
    raw = Path.join(dir, "IMG_100.CR2")
    File.write!(jpeg, "j")
    File.write!(raw, "r")

    assert Ingest.find_raw_sibling(jpeg) == raw

    tethered_jpeg = Path.join(dir, "shot-027.jpg")
    tethered_raw = Path.join(dir, "shot-028.cr2")
    File.write!(tethered_jpeg, "tj")
    File.write!(tethered_raw, "tr")

    assert Ingest.find_raw_sibling(tethered_jpeg) == tethered_raw
  end
end
