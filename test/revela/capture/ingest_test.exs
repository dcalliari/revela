defmodule Revela.Capture.IngestTest do
  use Revela.DataCase, async: false

  import ExUnit.CaptureLog

  alias Revela.Capture
  alias Revela.Capture.Ingest

  setup do
    dir =
      Path.join(
        System.tmp_dir!(),
        "revela-ingest-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    %{dir: dir}
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

  test "match exato de basename popula raw_path", %{dir: dir} do
    jpeg = touch!(dir, "20260804-133708-027.jpg")
    raw = touch!(dir, "20260804-133708-027.cr2")

    assert Ingest.find_raw_sibling(jpeg) == raw
    assert Ingest.match_raw_sibling(jpeg) == {:ok, raw}
  end

  test "match por indice adjacente (+1) no padrao gphoto2", %{dir: dir} do
    jpeg = touch!(dir, "20260804-133708-027.jpg")
    raw = touch!(dir, "20260804-133708-028.cr2")

    assert Ingest.find_raw_sibling(jpeg) == raw
  end

  test "rejeita RAW com indice N-1 no JPEG→RAW", %{dir: dir} do
    jpeg = touch!(dir, "20260804-133708-027.jpg")
    touch!(dir, "20260804-133708-026.cr2")

    assert Ingest.find_raw_sibling(jpeg) == nil
    assert Ingest.match_raw_sibling(jpeg) == :not_found
  end

  test "aceita skew de timestamp de 1s no nome", %{dir: dir} do
    jpeg = touch!(dir, "20260804-133708-027.jpg")
    raw = touch!(dir, "20260804-133709-028.cr2")

    assert Ingest.find_raw_sibling(jpeg) == raw
  end

  test "rejeita skew de timestamp acima da tolerancia", %{dir: dir} do
    jpeg = touch!(dir, "20260804-133708-027.jpg")
    touch!(dir, "20260804-133711-028.cr2")

    assert Ingest.find_raw_sibling(jpeg) == nil
    assert Ingest.match_raw_sibling(jpeg) == :not_found
  end

  test "sem candidato RAW retorna nil", %{dir: dir} do
    jpeg = touch!(dir, "20260804-133708-027.jpg")

    assert Ingest.find_raw_sibling(jpeg) == nil
    assert Ingest.match_raw_sibling(jpeg) == :not_found
  end

  test "nome fora do padrao nao crasha e nao casa no fallback", %{dir: dir} do
    jpeg = touch!(dir, "IMG_9999.jpg")
    touch!(dir, "IMG_9999_raw.cr2")
    touch!(dir, "20260804-133708-028.cr2")

    assert Ingest.find_raw_sibling(jpeg) == nil
    assert Ingest.parse_capture_path(jpeg) == :error
  end

  test "ambiguidade no ingest prefere o mais proximo e loga", %{dir: dir} do
    jpeg = touch!(dir, "20260804-133708-027.jpg")
    closer = touch!(dir, "20260804-133708-028.cr2")
    touch!(dir, "20260804-133709-028.cr3")

    log =
      capture_log(fn ->
        assert Ingest.match_raw_sibling(jpeg, on_ambiguity: :prefer_closest) == {:ok, closer}
      end)

    assert log =~ "RAW sibling ambiguo"
  end

  test "ambiguidade no backfill e skip", %{dir: dir} do
    jpeg = touch!(dir, "20260804-133708-027.jpg")
    touch!(dir, "20260804-133708-028.cr2")
    touch!(dir, "20260804-133709-028.cr3")

    assert Ingest.match_raw_sibling(jpeg, on_ambiguity: :skip) == :ambiguous
  end

  test "RAW ja claimed nao e reutilizado", %{dir: dir} do
    jpeg = touch!(dir, "20260804-133708-027.jpg")
    raw = touch!(dir, "20260804-133708-028.cr2")

    assert Ingest.find_raw_sibling(jpeg, taken: MapSet.new([raw])) == nil
  end

  test "attach_raw associa RAW que chegou depois do JPEG", %{dir: dir} do
    jpeg = touch!(dir, "20260804-133708-027.jpg")

    {:ok, photo} =
      Capture.create_photo(%{
        web_path: "/uploads/x.jpg",
        original_path: jpeg,
        raw_path: nil,
        shot_at: DateTime.utc_now()
      })

    assert photo.raw_path in [nil, ""]

    raw = touch!(dir, "20260804-133709-028.cr2")

    assert {:ok, updated} = Ingest.attach_raw(raw)
    assert updated.id == photo.id
    assert updated.raw_path == raw
  end

  test "attach_raw rejeita RAW com indice N-1 (so N+1)", %{dir: dir} do
    # JPEG do tiro 2 (indice 028); RAW do tiro 1 (indice 027) nao e elegivel.
    jpeg = touch!(dir, "20260804-133708-028.jpg")

    {:ok, photo} =
      Capture.create_photo(%{
        web_path: "/uploads/wrong-dir.jpg",
        original_path: jpeg,
        raw_path: nil,
        shot_at: DateTime.utc_now()
      })

    raw = touch!(dir, "20260804-133708-027.cr2")

    assert Ingest.attach_raw(raw) == :ignore
    assert Capture.get_photo!(photo.id).raw_path in [nil, ""]
  end

  test "JPEG-only permanece sem raw_path", %{dir: dir} do
    jpeg = touch!(dir, "20260804-133708-027.jpg")

    {:ok, photo} =
      Capture.create_photo(%{
        web_path: "/uploads/y.jpg",
        original_path: jpeg,
        raw_path: nil,
        shot_at: DateTime.utc_now()
      })

    assert Ingest.attach_raw(Path.join(dir, "missing.cr2")) == :ignore
    assert Capture.get_photo!(photo.id).raw_path in [nil, ""]
  end

  test "backfill preenche match univoco, pula ambiguo e e idempotente", %{dir: dir} do
    jpeg_ok = touch!(dir, "20260804-133708-027.jpg")
    raw_ok = touch!(dir, "20260804-133708-028.cr2")

    jpeg_amb = touch!(dir, "20260804-140000-010.jpg")
    touch!(dir, "20260804-140000-011.cr2")
    touch!(dir, "20260804-140001-011.cr3")

    jpeg_miss = touch!(dir, "20260804-150000-001.jpg")

    {:ok, photo_ok} =
      Capture.create_photo(%{
        web_path: "/uploads/ok.jpg",
        original_path: jpeg_ok,
        raw_path: nil,
        shot_at: DateTime.utc_now()
      })

    {:ok, photo_amb} =
      Capture.create_photo(%{
        web_path: "/uploads/amb.jpg",
        original_path: jpeg_amb,
        raw_path: nil,
        shot_at: DateTime.utc_now()
      })

    {:ok, photo_miss} =
      Capture.create_photo(%{
        web_path: "/uploads/miss.jpg",
        original_path: jpeg_miss,
        raw_path: nil,
        shot_at: DateTime.utc_now()
      })

    {:ok, photo_filled} =
      Capture.create_photo(%{
        web_path: "/uploads/filled.jpg",
        original_path: touch!(dir, "20260804-160000-001.jpg"),
        raw_path: "/already/set.cr2",
        shot_at: DateTime.utc_now()
      })

    dry =
      capture_log(fn ->
        assert Ingest.backfill_raw_paths(dry_run: true) == %{
                 matched: 1,
                 ambiguous: 1,
                 not_found: 1,
                 skipped_missing_file: 0
               }
      end)

    assert dry =~ "ambiguidade"
    assert Capture.get_photo!(photo_ok.id).raw_path in [nil, ""]

    log =
      capture_log(fn ->
        assert Ingest.backfill_raw_paths(dry_run: false) == %{
                 matched: 1,
                 ambiguous: 1,
                 not_found: 1,
                 skipped_missing_file: 0
               }
      end)

    assert log =~ "ambiguidade"
    assert Capture.get_photo!(photo_ok.id).raw_path == raw_ok
    assert Capture.get_photo!(photo_amb.id).raw_path in [nil, ""]
    assert Capture.get_photo!(photo_miss.id).raw_path in [nil, ""]
    assert Capture.get_photo!(photo_filled.id).raw_path == "/already/set.cr2"

    assert Ingest.backfill_raw_paths(dry_run: false) == %{
             matched: 0,
             ambiguous: 1,
             not_found: 1,
             skipped_missing_file: 0
           }
  end

  test "update_raw_path nao sobrescreve raw_path existente", %{dir: dir} do
    jpeg = touch!(dir, "20260804-133708-027.jpg")

    {:ok, photo} =
      Capture.create_photo(%{
        web_path: "/uploads/z.jpg",
        original_path: jpeg,
        raw_path: "/keep/me.cr2",
        shot_at: DateTime.utc_now()
      })

    assert {:ok, same} = Capture.update_raw_path(photo, touch!(dir, "20260804-133708-028.cr2"))
    assert same.raw_path == "/keep/me.cr2"
  end

  test "update_raw_path com struct stale e outro RAW ja gravado retorna erro", %{dir: dir} do
    jpeg = touch!(dir, "20260804-133708-027.jpg")
    other = touch!(dir, "20260804-133708-028.cr2")
    attempted = touch!(dir, "20260804-133709-030.cr2")

    {:ok, photo} =
      Capture.create_photo(%{
        web_path: "/uploads/stale.jpg",
        original_path: jpeg,
        raw_path: nil,
        shot_at: DateTime.utc_now()
      })

    assert {:ok, _} = Capture.update_raw_path(photo, other)

    assert {:error, :already_has_other_raw} = Capture.update_raw_path(photo, attempted)
    assert Capture.get_photo!(photo.id).raw_path == other
  end

  test "update_raw_path rejeita mesmo RAW em duas fotos", %{dir: dir} do
    raw = touch!(dir, "20260804-133708-028.cr2")

    {:ok, first} =
      Capture.create_photo(%{
        web_path: "/uploads/a.jpg",
        original_path: touch!(dir, "20260804-133708-027.jpg"),
        raw_path: nil,
        shot_at: DateTime.utc_now()
      })

    {:ok, second} =
      Capture.create_photo(%{
        web_path: "/uploads/b.jpg",
        original_path: touch!(dir, "20260804-133709-029.jpg"),
        raw_path: nil,
        shot_at: DateTime.utc_now()
      })

    assert {:ok, updated} = Capture.update_raw_path(first, raw)
    assert updated.raw_path == raw
    assert {:error, _} = Capture.update_raw_path(second, raw)
    assert Capture.get_photo!(second.id).raw_path in [nil, ""]
  end

  defp touch!(dir, name) do
    path = Path.join(dir, name)
    File.write!(path, "x")
    path
  end
end
