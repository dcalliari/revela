defmodule Revela.Capture.CardImportTest do
  use Revela.DataCase, async: true

  alias Revela.Capture
  alias Revela.Capture.CardImport

  setup do
    source =
      Path.join(System.tmp_dir!(), "revela-card-import-src-#{System.unique_integer([:positive])}")

    dest =
      Path.join(System.tmp_dir!(), "revela-card-import-dst-#{System.unique_integer([:positive])}")

    File.mkdir_p!(source)
    File.mkdir_p!(dest)

    on_exit(fn ->
      File.rm_rf(source)
      File.rm_rf(dest)
    end)

    %{source: source, dest: dest, preview_fun: &stub_preview/2}
  end

  test "recusa import sem editorial ativo", %{source: source, preview_fun: preview_fun} do
    assert is_nil(Capture.current_editorial_id())
    write_jpeg!(Path.join(source, "IMG_0001.JPG"), "solo")

    assert {:error, :no_active_editorial} =
             CardImport.import_folder(source, preview_fun: preview_fun)

    assert Capture.list_photos() == []
    assert Repo.aggregate(Capture.Photo, :count) == 0
  end

  test "importa JPEG avulso para o editorial ativo", %{
    source: source,
    dest: dest,
    preview_fun: preview_fun
  } do
    {:ok, editorial} = Capture.start_editorial("Cartao JPEG", dest)
    write_jpeg!(Path.join(source, "IMG_0001.JPG"), "jpeg-only")

    assert {:ok, %{imported: 1, skipped: 0, errors: []}} =
             CardImport.import_folder(source, preview_fun: preview_fun)

    [photo] = Capture.list_photos()
    assert photo.editorial_id == editorial.id
    assert photo.original_filename == "IMG_0001.JPG"
    assert photo.original_path == Path.join(dest, "IMG_0001.JPG")
    assert is_nil(photo.raw_path)
    assert photo.source_hash
    assert File.exists?(photo.original_path)
    assert photo.web_path =~ "/uploads/#{editorial.id}/IMG_0001.jpg"
  end

  test "importa RAW avulso e preenche raw_path", %{
    source: source,
    dest: dest,
    preview_fun: preview_fun
  } do
    {:ok, _editorial} = Capture.start_editorial("Cartao RAW", dest)
    write_bytes!(Path.join(source, "IMG_0002.CR2"), "raw-only-bytes")

    assert {:ok, %{imported: 1, skipped: 0, errors: []}} =
             CardImport.import_folder(source, preview_fun: preview_fun)

    [photo] = Capture.list_photos()
    assert photo.original_filename == "IMG_0002.CR2"
    assert photo.raw_path == Path.join(dest, "IMG_0002.CR2")
    assert photo.original_path == photo.raw_path
    assert File.exists?(photo.raw_path)
  end

  test "casa JPEG+RAW pelo mesmo stem e preenche raw_path", %{
    source: source,
    dest: dest,
    preview_fun: preview_fun
  } do
    {:ok, _editorial} = Capture.start_editorial("Cartao Par", dest)
    write_jpeg!(Path.join(source, "IMG_0010.JPG"), "pair-jpeg")
    write_bytes!(Path.join(source, "IMG_0010.CR2"), "pair-raw")

    assert {:ok, %{imported: 1, skipped: 0, errors: []}} =
             CardImport.import_folder(source, preview_fun: preview_fun)

    photos = Capture.list_photos()
    assert length(photos) == 1
    [photo] = photos
    assert photo.original_filename == "IMG_0010.JPG"
    assert photo.original_path == Path.join(dest, "IMG_0010.JPG")
    assert photo.raw_path == Path.join(dest, "IMG_0010.CR2")
  end

  test "casa RAW irmao por indice adjacente (estilo tethered)", %{
    source: source,
    dest: dest,
    preview_fun: preview_fun
  } do
    {:ok, _editorial} = Capture.start_editorial("Cartao Adj", dest)
    write_jpeg!(Path.join(source, "20260804-133708-027.jpg"), "adj-jpeg")
    write_bytes!(Path.join(source, "20260804-133708-028.cr2"), "adj-raw")

    assert {:ok, %{imported: 1, skipped: 0, errors: []}} =
             CardImport.import_folder(source, preview_fun: preview_fun)

    [photo] = Capture.list_photos()
    assert photo.raw_path == Path.join(dest, "20260804-133708-028.cr2")
  end

  test "reimportar a mesma pasta nao cria duplicatas", %{
    source: source,
    dest: dest,
    preview_fun: preview_fun
  } do
    {:ok, _editorial} = Capture.start_editorial("Cartao Idem", dest)
    write_jpeg!(Path.join(source, "IMG_0099.JPG"), "idempotent")
    write_bytes!(Path.join(source, "IMG_0099.CR2"), "idempotent-raw")

    assert {:ok, %{imported: 1, skipped: 0, errors: []}} =
             CardImport.import_folder(source, preview_fun: preview_fun)

    assert {:ok, %{imported: 0, skipped: 1, errors: []}} =
             CardImport.import_folder(source, preview_fun: preview_fun)

    assert length(Capture.list_photos()) == 1
    assert Repo.aggregate(Capture.Photo, :count) == 1
  end

  test "nunca escreve no limbo sem editorial", %{source: source, preview_fun: preview_fun} do
    write_jpeg!(Path.join(source, "IMG_LIMBO.JPG"), "limbo")

    assert {:error, :no_active_editorial} =
             CardImport.import_folder(source, preview_fun: preview_fun)

    uploads = Application.app_dir(:revela, "priv/static/uploads/_sem-editorial")
    refute File.exists?(Path.join(uploads, "IMG_LIMBO.jpg"))
  end

  defp stub_preview(_src, dest) do
    File.mkdir_p!(Path.dirname(dest))
    File.write!(dest, <<0xFF, 0xD8, 0xFF, 0xD9>>)
    :ok
  end

  defp write_jpeg!(path, contents) do
    # conteudo distinto por teste (hash); extensao jpeg basta para o import
    File.write!(path, "JPEG-FAKE:" <> contents)
  end

  defp write_bytes!(path, contents), do: File.write!(path, contents)
end
