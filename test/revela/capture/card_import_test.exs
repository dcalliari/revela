defmodule Revela.Capture.CardImportTest do
  use Revela.DataCase, async: false

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

  test "reimportacao anexa RAW que apareceu depois do JPEG", %{
    source: source,
    dest: dest,
    preview_fun: preview_fun
  } do
    {:ok, _editorial} = Capture.start_editorial("Cartao RAW tardio", dest)
    jpeg = Path.join(source, "IMG_0002.JPG")
    raw = Path.join(source, "IMG_0002.CR2")
    write_jpeg!(jpeg, "late-jpeg")

    assert {:ok, %{imported: 1}} = CardImport.import_folder(source, preview_fun: preview_fun)
    write_bytes!(raw, "late-raw")

    assert {:ok, %{imported: 0, skipped: 1, errors: []}} =
             CardImport.import_folder(source, preview_fun: preview_fun)

    [photo] = Capture.list_photos()
    assert photo.raw_path == Path.join(dest, "IMG_0002.CR2")
    assert File.exists?(photo.raw_path)
  end

  test "follow-up somente RAW anexa na foto JPEG existente", %{
    source: source,
    dest: dest,
    preview_fun: preview_fun
  } do
    {:ok, _editorial} = Capture.start_editorial("Cartao follow-up RAW", dest)
    jpeg = Path.join(source, "IMG_0003.JPG")
    raw = Path.join(source, "IMG_0003.CR2")
    write_jpeg!(jpeg, "follow-jpeg")

    assert {:ok, %{imported: 1}} = CardImport.import_folder(source, preview_fun: preview_fun)
    File.rm!(jpeg)
    write_bytes!(raw, "follow-raw")

    assert {:ok, %{imported: 0, skipped: 1, errors: []}} =
             CardImport.import_folder(source, preview_fun: preview_fun)

    [photo] = Capture.list_photos()
    assert photo.raw_path == Path.join(dest, "IMG_0003.CR2")
    assert length(Capture.list_photos()) == 1
  end

  test "JPEG que chega depois do RAW atualiza a mesma foto", %{
    source: source,
    dest: dest,
    preview_fun: preview_fun
  } do
    {:ok, _editorial} = Capture.start_editorial("Cartao JPEG tardio", dest)
    jpeg = Path.join(source, "IMG_0004.JPG")
    raw = Path.join(source, "IMG_0004.CR2")
    write_bytes!(raw, "raw-first")

    assert {:ok, %{imported: 1}} = CardImport.import_folder(source, preview_fun: preview_fun)
    File.rm!(raw)
    write_jpeg!(jpeg, "jpeg-later")

    assert {:ok, %{imported: 0, skipped: 1, errors: []}} =
             CardImport.import_folder(source, preview_fun: preview_fun)

    [photo] = Capture.list_photos()
    assert photo.original_filename == "IMG_0004.JPG"
    assert photo.raw_path == Path.join(dest, "IMG_0004.CR2")
    assert photo.original_path == Path.join(dest, "IMG_0004.JPG")
  end

  test "RAW reimportado depois do merge JPEG continua idempotente", %{
    source: source,
    dest: dest,
    preview_fun: preview_fun
  } do
    {:ok, _editorial} = Capture.start_editorial("Cartao RAW merge idem", dest)
    jpeg = Path.join(source, "IMG_0006.JPG")
    raw = Path.join(source, "IMG_0006.CR2")
    write_bytes!(raw, "raw-first")

    assert {:ok, %{imported: 1}} = CardImport.import_folder(source, preview_fun: preview_fun)
    File.rm!(raw)
    write_jpeg!(jpeg, "jpeg-later")

    assert {:ok, %{imported: 0, skipped: 1}} =
             CardImport.import_folder(source, preview_fun: preview_fun)

    File.rm!(jpeg)
    write_bytes!(raw, "raw-first")

    assert {:ok, %{imported: 0, skipped: 1, errors: []}} =
             CardImport.import_folder(source, preview_fun: preview_fun)

    assert length(Capture.list_photos()) == 1
  end

  test "RAW tardio respeita editorial ativo quando a pasta e reutilizada", %{
    source: source,
    dest: dest,
    preview_fun: preview_fun
  } do
    {:ok, first} = Capture.start_editorial("Cartao antigo", dest)
    write_jpeg!(Path.join(source, "IMG_0005.JPG"), "old-jpeg")
    assert {:ok, %{imported: 1}} = CardImport.import_folder(source, preview_fun: preview_fun)
    Capture.finish_editorial()

    {:ok, second} = Capture.start_editorial("Cartao atual", dest)
    File.rm!(Path.join(source, "IMG_0005.JPG"))
    write_bytes!(Path.join(source, "IMG_0005.CR2"), "new-raw")

    assert {:ok, %{imported: 1, skipped: 0, errors: []}} =
             CardImport.import_folder(source, preview_fun: preview_fun)

    [photo] = Repo.all(from p in Capture.Photo, where: p.editorial_id == ^second.id)
    assert photo.editorial_id == second.id

    assert Repo.aggregate(from(p in Capture.Photo, where: p.editorial_id == ^first.id), :count) ==
             1
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

  test "RAW avulso cria Photo mesmo sem preview decodificavel", %{source: source, dest: dest} do
    {:ok, _editorial} = Capture.start_editorial("Cartao RAW sem preview", dest)
    raw = Path.join(source, "IMG_NOPREVIEW.CR2")
    write_bytes!(raw, "raw-undecodable")
    preview_fun = fn _src, _dest -> {:error, :unsupported_raw} end

    assert {:ok, %{imported: 1, skipped: 0, errors: []}} =
             CardImport.import_folder(source, preview_fun: preview_fun)

    [photo] = Capture.list_photos()
    assert photo.web_path == nil
    assert photo.raw_path == Path.join(dest, "IMG_NOPREVIEW.CR2")
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

  test "pula JPEG cujo conteudo ja existe em foto tethered do editorial", %{
    source: source,
    dest: dest,
    preview_fun: preview_fun
  } do
    {:ok, _editorial} = Capture.start_editorial("Cartao Tethered Dedupe", dest)
    jpeg = Path.join(source, "IMG_TETHERED.JPG")
    write_jpeg!(jpeg, "already-tethered")

    {:ok, _photo} =
      Capture.create_photo(%{
        web_path: "/uploads/existing.jpg",
        original_path: jpeg,
        raw_path: nil,
        shot_at: DateTime.utc_now()
      })

    assert {:ok, %{imported: 0, skipped: 1, errors: []}} =
             CardImport.import_folder(source, preview_fun: preview_fun)

    assert length(Capture.list_photos()) == 1
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

  test "importa arquivos um nivel abaixo (DCIM/CAMFOLDER)", %{
    source: source,
    dest: dest,
    preview_fun: preview_fun
  } do
    {:ok, _editorial} = Capture.start_editorial("Cartao Nested", dest)
    dcim = Path.join(source, "DCIM")
    cam = Path.join(dcim, "CAMFOLDER")
    File.mkdir_p!(cam)
    write_jpeg!(Path.join(dcim, "IMG_TOP.JPG"), "dcim-top")
    write_jpeg!(Path.join(cam, "IMG_NESTED.JPG"), "camfolder")

    assert {:ok, %{imported: 2, skipped: 0, errors: []}} =
             CardImport.import_folder(dcim, preview_fun: preview_fun)

    names =
      Capture.list_photos()
      |> Enum.map(& &1.original_filename)
      |> Enum.sort()

    assert names == ["IMG_NESTED.JPG", "IMG_TOP.JPG"]
  end

  test "preview usa stem do destino quando o basename colide", %{
    source: source,
    dest: dest,
    preview_fun: preview_fun
  } do
    {:ok, editorial} = Capture.start_editorial("Cartao Collide", dest)
    File.write!(Path.join(dest, "IMG_SAME.JPG"), "already-there")
    write_jpeg!(Path.join(source, "IMG_SAME.JPG"), "imported-different")

    assert {:ok, %{imported: 1, skipped: 0, errors: []}} =
             CardImport.import_folder(source, preview_fun: preview_fun)

    [photo] = Capture.list_photos()
    assert photo.original_filename == "IMG_SAME.JPG"
    assert Path.basename(photo.original_path) =~ "import-"
    assert photo.web_path =~ "/uploads/#{editorial.id}/import-"
    refute photo.web_path == "/uploads/#{editorial.id}/IMG_SAME.jpg"
  end

  test "RAW follow-up encontra JPEG cujo destino foi renomeado por colisao", %{
    source: source,
    dest: dest,
    preview_fun: preview_fun
  } do
    {:ok, _editorial} = Capture.start_editorial("Cartao Colisao RAW", dest)
    File.write!(Path.join(dest, "IMG_COLLIDE.JPG"), "existing")
    jpeg = Path.join(source, "IMG_COLLIDE.JPG")
    raw = Path.join(source, "IMG_COLLIDE.CR2")
    write_jpeg!(jpeg, "collision-jpeg")

    assert {:ok, %{imported: 1}} = CardImport.import_folder(source, preview_fun: preview_fun)
    File.rm!(jpeg)
    write_bytes!(raw, "collision-raw")

    assert {:ok, %{imported: 0, skipped: 1, errors: []}} =
             CardImport.import_folder(source, preview_fun: preview_fun)

    [photo] = Capture.list_photos()
    assert photo.raw_path == Path.join(dest, "IMG_COLLIDE.CR2")
    assert length(Capture.list_photos()) == 1
  end

  test "nunca escreve no limbo sem editorial", %{source: source, preview_fun: preview_fun} do
    write_jpeg!(Path.join(source, "IMG_LIMBO.JPG"), "limbo")

    assert {:error, :no_active_editorial} =
             CardImport.import_folder(source, preview_fun: preview_fun)

    uploads = Application.app_dir(:revela, "priv/static/uploads/_sem-editorial")
    refute File.exists?(Path.join(uploads, "IMG_LIMBO.jpg"))
  end

  test "mantem editorial e preview pinados se o editorial terminar no meio do import", %{
    source: source,
    dest: dest
  } do
    {:ok, editorial} = Capture.start_editorial("Cartao Mid Finish", dest)
    write_jpeg!(Path.join(source, "IMG_PIN.JPG"), "pinned-mid-finish")

    preview_fun = fn src, dest_path ->
      Capture.finish_editorial()
      stub_preview(src, dest_path)
    end

    assert {:ok, %{imported: 1, skipped: 0, errors: []}} =
             CardImport.import_folder(source, preview_fun: preview_fun)

    assert is_nil(Capture.current_editorial_id())
    assert Capture.list_photos() == []

    [photo] = Repo.all(from p in Capture.Photo, where: p.editorial_id == ^editorial.id)
    assert photo.editorial_id == editorial.id
    assert photo.web_path == "/uploads/#{editorial.id}/IMG_PIN.jpg"
    refute String.contains?(photo.web_path, "_sem-editorial")

    uploads = Application.app_dir(:revela, "priv/static/uploads")
    assert File.exists?(Path.join(uploads, "#{editorial.id}/IMG_PIN.jpg"))
    refute File.exists?(Path.join(uploads, "_sem-editorial/IMG_PIN.jpg"))
  end

  test "arquivo ilegivel no cartao vira erro controlado, sem crash", %{
    source: source,
    dest: dest,
    preview_fun: preview_fun
  } do
    {:ok, _editorial} = Capture.start_editorial("Cartao Unreadable", dest)
    bad = Path.join(source, "IMG_BAD.JPG")
    write_jpeg!(bad, "unreadable-card")
    File.chmod!(bad, 0o000)

    on_exit(fn ->
      File.chmod!(bad, 0o644)
    end)

    assert {:ok, %{imported: 0, skipped: 0, errors: errors}} =
             CardImport.import_folder(source, preview_fun: preview_fun)

    assert [{"IMG_BAD.JPG", reason}] = errors
    assert is_binary(reason)
    assert Capture.list_photos() == []
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
