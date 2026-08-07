defmodule Revela.Capture.IngestTest do
  use Revela.DataCase, async: false

  alias Revela.Capture
  alias Revela.Capture.Ingest

  setup do
    previous = Application.get_env(:revela, :keep_camera_jpeg)
    on_exit(fn -> Application.put_env(:revela, :keep_camera_jpeg, previous) end)

    tmp = Path.join(System.tmp_dir!(), "revela-ingest-#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    on_exit(fn -> File.rm_rf!(tmp) end)

    %{tmp: tmp}
  end

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

  test "apos preview, descarta JPEG da camera e mantem RAW e preview (padrao)", %{tmp: tmp} do
    Application.put_env(:revela, :keep_camera_jpeg, false)
    {:ok, editorial} = Capture.start_editorial("Discard", tmp)
    {jpeg_path, raw_path} = write_shot_pair(tmp, "shot-discard")

    assert {:ok, photo} = Ingest.process(jpeg_path)

    refute File.exists?(jpeg_path)
    assert File.exists?(raw_path)
    assert photo.original_path == nil
    assert photo.raw_path == raw_path
    assert photo.editorial_id == editorial.id

    web_abs =
      Path.join(
        Application.app_dir(:revela, "priv/static/uploads"),
        "#{editorial.id}/shot-discard.jpg"
      )

    assert File.exists?(web_abs)
    assert photo.web_path == "/uploads/#{editorial.id}/shot-discard.jpg"
  end

  test "mantem JPEG da camera quando keep_camera_jpeg esta ativo", %{tmp: tmp} do
    Application.put_env(:revela, :keep_camera_jpeg, true)
    {:ok, _editorial} = Capture.start_editorial("Keep", tmp)
    {jpeg_path, raw_path} = write_shot_pair(tmp, "shot-keep")

    assert {:ok, photo} = Ingest.process(jpeg_path)

    assert File.exists?(jpeg_path)
    assert File.exists?(raw_path)
    assert photo.original_path == jpeg_path
    assert photo.raw_path == raw_path
  end

  test "falha ao gerar preview nao apaga o JPEG da camera", %{tmp: tmp} do
    Application.put_env(:revela, :keep_camera_jpeg, false)
    {:ok, _editorial} = Capture.start_editorial("Fail", tmp)

    jpeg_path = Path.join(tmp, "not-an-image.jpg")
    File.write!(jpeg_path, "isto-nao-e-um-jpeg-valido")

    assert {:error, _reason} = Ingest.process(jpeg_path)
    assert File.exists?(jpeg_path)
    assert Capture.list_photos() == []
  end

  defp write_shot_pair(dir, stem) do
    jpeg_path = Path.join(dir, stem <> ".jpg")
    raw_path = Path.join(dir, stem <> ".cr2")

    {_, 0} =
      System.cmd(
        "magick",
        ["-size", "32x24", "xc:#336699", jpeg_path],
        stderr_to_stdout: true
      )

    File.write!(raw_path, :binary.copy(<<1>>, 64))
    {jpeg_path, raw_path}
  end
end
