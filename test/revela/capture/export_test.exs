defmodule Revela.Capture.ExportTest do
  use Revela.DataCase, async: false

  alias Revela.Capture
  alias Revela.Capture.Export

  setup do
    tmp = Path.join(System.tmp_dir!(), "revela-export-#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    on_exit(fn -> File.rm_rf!(tmp) end)
    %{tmp: tmp}
  end

  test "copia RAW para pasta nomeada pela cor do revisor", %{tmp: tmp} do
    {:ok, editorial} = Capture.start_editorial("Export", Path.join(tmp, "ed"))
    raw = Path.join(tmp, "shot.CR2")
    File.write!(raw, "raw-bytes")

    {:ok, photo} =
      Capture.create_photo(%{
        web_path: "/uploads/#{editorial.id}/shot.jpg",
        original_path: Path.join(tmp, "shot.jpg"),
        raw_path: raw
      })

    {:ok, _} = Capture.set_label(photo.id, "host", "host", 0)

    dest = Path.join(tmp, "out")
    assert {:ok, result} = Export.export(dest: dest, reviewer_id: "host")

    assert length(result.exported) == 1
    assert result.warnings == []
    assert Enum.find(result.exported, &(&1.folder == "vermelho"))
    assert File.read!(Path.join(dest, "vermelho/shot.CR2")) == "raw-bytes"
    assert File.exists?(raw)
  end

  test "sem raw_path exporta JPEG e registra aviso", %{tmp: tmp} do
    {:ok, editorial} = Capture.start_editorial("Export JPEG", Path.join(tmp, "ed-jpg"))
    jpeg = Path.join(tmp, "shot.jpg")
    File.write!(jpeg, "jpeg-bytes")

    {:ok, photo} =
      Capture.create_photo(%{
        web_path: "/uploads/#{editorial.id}/shot.jpg",
        original_path: jpeg,
        raw_path: nil
      })

    {:ok, _} = Capture.set_label(photo.id, "host", "host", 2)

    dest = Path.join(tmp, "out-jpg")
    assert {:ok, result} = Export.export(dest: dest)

    assert [%{folder: "verde", source: ^jpeg}] = result.exported
    assert [%{photo_id: id, message: msg}] = result.warnings
    assert id == photo.id
    assert msg =~ "raw_path ausente"
    assert File.read!(Path.join(dest, "verde/shot.jpg")) == "jpeg-bytes"
  end

  test "filtra por cor e por photo_ids", %{tmp: tmp} do
    {:ok, _editorial} = Capture.start_editorial("Filtro", Path.join(tmp, "ed-f"))

    photos =
      for {color, name} <- [{0, "a"}, {1, "b"}, {2, "c"}] do
        path = Path.join(tmp, "#{name}.CR2")
        File.write!(path, name)

        {:ok, photo} =
          Capture.create_photo(%{
            web_path: "/uploads/#{name}.jpg",
            original_path: path,
            raw_path: path
          })

        {:ok, _} = Capture.set_label(photo.id, "host", "host", color)
        photo
      end

    [p0, p1, _p2] = photos
    dest = Path.join(tmp, "out-f")

    assert {:ok, result} =
             Export.export(
               dest: dest,
               colors: [0, 1],
               photo_ids: [p0.id, p1.id]
             )

    folders = result.exported |> Enum.map(& &1.folder) |> Enum.sort()
    assert folders == ["amarelo", "vermelho"]
    refute File.dir?(Path.join(dest, "verde"))
  end

  test "move em vez de copiar quando mode: :move e atualiza raw_path", %{tmp: tmp} do
    {:ok, _} = Capture.start_editorial("Move", Path.join(tmp, "ed-m"))
    raw = Path.join(tmp, "move.CR2")
    File.write!(raw, "x")

    {:ok, photo} =
      Capture.create_photo(%{
        web_path: "/uploads/move.jpg",
        raw_path: raw
      })

    {:ok, _} = Capture.set_label(photo.id, "host", "host", 3)

    dest = Path.join(tmp, "out-m")
    assert {:ok, _} = Export.export(dest: dest, mode: :move)
    moved = Path.join(dest, "azul/move.CR2")
    assert File.read!(moved) == "x"
    refute File.exists?(raw)
    assert Revela.Repo.get!(Revela.Capture.Photo, photo.id).raw_path == moved
  end

  test "falha ao atualizar path apos move devolve arquivo a origem", %{tmp: tmp} do
    {:ok, _} = Capture.start_editorial("Move rollback", Path.join(tmp, "ed-rb"))
    raw = Path.join(tmp, "rollback.CR2")
    File.write!(raw, "rb")

    {:ok, photo} =
      Capture.create_photo(%{
        web_path: "/uploads/rollback.jpg",
        raw_path: raw
      })

    {:ok, _} = Capture.set_label(photo.id, "host", "host", 0)

    dest = Path.join(tmp, "out-rb")

    assert {:ok, result} =
             Export.export(
               dest: dest,
               mode: :move,
               path_updater: fn _photo, _kind, _dest -> {:error, :simulated_db_failure} end
             )

    assert result.exported == []

    assert [%{photo_id: id, reason: {:path_update_failed, :simulated_db_failure}}] =
             result.skipped

    assert id == photo.id
    assert File.read!(raw) == "rb"
    refute File.exists?(Path.join(dest, "vermelho/rollback.CR2"))
    assert Revela.Repo.get!(Revela.Capture.Photo, photo.id).raw_path == raw
  end

  test "move cross-device limpa dest se rm da origem falhar" do
    {:ok, _} =
      Capture.start_editorial(
        "Exdev cleanup",
        Path.join(System.tmp_dir!(), "revela-ed-exdev-#{System.unique_integer([:positive])}")
      )

    # Source on the worktree disk; dest under /tmp (tmpfs) so rename returns :exdev.
    src_dir =
      Path.join(
        File.cwd!(),
        "tmp/exdev-src-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(src_dir)
    raw = Path.join(src_dir, "exdev.CR2")
    File.write!(raw, "exdev-bytes")
    File.chmod!(src_dir, 0o555)

    on_exit(fn ->
      File.chmod!(src_dir, 0o755)
      File.rm_rf!(src_dir)
    end)

    {:ok, photo} =
      Capture.create_photo(%{
        web_path: "/uploads/exdev.jpg",
        raw_path: raw
      })

    {:ok, _} = Capture.set_label(photo.id, "host", "host", 0)

    dest = Path.join(System.tmp_dir!(), "revela-exdev-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(dest) end)

    assert {:ok, result} = Export.export(dest: dest, mode: :move)
    assert result.exported == []

    assert [%{photo_id: id, reason: {:transfer_failed, _reason, ^raw, dest_file}}] =
             result.skipped

    assert id == photo.id
    refute File.exists?(dest_file)
    assert File.read!(raw) == "exdev-bytes"
    assert Revela.Repo.get!(Revela.Capture.Photo, photo.id).raw_path == raw
  end

  test "recusa move quando a unica fonte e o preview web", %{tmp: tmp} do
    {:ok, editorial} = Capture.start_editorial("Preview move", Path.join(tmp, "ed-pv"))

    uploads =
      Path.join(Application.app_dir(:revela, "priv/static/uploads"), to_string(editorial.id))

    File.mkdir_p!(uploads)
    preview = Path.join(uploads, "only.jpg")
    File.write!(preview, "preview-bytes")
    on_exit(fn -> File.rm_rf!(uploads) end)

    {:ok, photo} =
      Capture.create_photo(%{
        web_path: "/uploads/#{editorial.id}/only.jpg",
        original_path: nil,
        raw_path: nil
      })

    {:ok, _} = Capture.set_label(photo.id, "host", "host", 1)

    dest = Path.join(tmp, "out-pv")
    assert {:ok, result} = Export.export(dest: dest, mode: :move)
    assert result.exported == []
    assert [%{photo_id: id, reason: :preview_move_refused}] = result.skipped
    assert id == photo.id
    assert File.exists?(preview)
  end

  test "rejeita cores invalidas em vez de filtrar em silencio", %{tmp: tmp} do
    {:ok, _} = Capture.start_editorial("Bad color", Path.join(tmp, "ed-bc"))

    assert {:error, {:invalid_colors, [5]}} =
             Export.export(dest: Path.join(tmp, "x"), colors: [5])

    assert {:error, {:invalid_colors, []}} = Export.export(dest: Path.join(tmp, "x"), colors: [])
  end

  test "reporta photo_ids ausentes ou de outro editorial", %{tmp: tmp} do
    {:ok, ed_a} = Capture.start_editorial("Ids A", Path.join(tmp, "ed-a"))
    raw = Path.join(tmp, "a.CR2")
    File.write!(raw, "a")

    {:ok, photo_a} =
      Capture.create_photo(%{web_path: "/uploads/a.jpg", raw_path: raw})

    {:ok, _} = Capture.set_label(photo_a.id, "host", "host", 0)
    Capture.finish_editorial()

    {:ok, _ed_b} = Capture.start_editorial("Ids B", Path.join(tmp, "ed-b"))
    missing_id = photo_a.id + 999_999

    dest = Path.join(tmp, "out-ids")

    assert {:ok, result} =
             Export.export(
               dest: dest,
               photo_ids: [photo_a.id, missing_id]
             )

    assert result.exported == []

    reasons =
      result.skipped
      |> Enum.map(&{&1.photo_id, &1.reason})
      |> Map.new()

    assert reasons[photo_a.id] == {:wrong_editorial, ed_a.id}
    assert reasons[missing_id] == :not_found
  end

  test "exige editorial ativo ou --editorial", %{tmp: tmp} do
    Capture.finish_editorial()
    assert {:error, :no_active_editorial} = Export.export(dest: Path.join(tmp, "x"))
  end

  test "rejeita editorial_id inexistente", %{tmp: tmp} do
    Capture.finish_editorial()
    missing_id = 999_999_999

    assert {:error, :editorial_not_found} =
             Export.export(dest: Path.join(tmp, "x"), editorial_id: missing_id)
  end

  test "copia falha limpa dest parcial", %{tmp: tmp} do
    {:ok, _} = Capture.start_editorial("Copy cleanup", Path.join(tmp, "ed-cc"))
    raw = Path.join(tmp, "copyfail.CR2")
    File.write!(raw, "copy-bytes")
    File.chmod!(raw, 0o000)

    on_exit(fn ->
      File.chmod!(raw, 0o644)
    end)

    {:ok, photo} =
      Capture.create_photo(%{
        web_path: "/uploads/copyfail.jpg",
        raw_path: raw
      })

    {:ok, _} = Capture.set_label(photo.id, "host", "host", 0)

    dest = Path.join(tmp, "out-cc")
    assert {:ok, result} = Export.export(dest: dest)
    assert result.exported == []

    assert [%{photo_id: id, reason: {:transfer_failed, _reason, ^raw, dest_file}}] =
             result.skipped

    assert id == photo.id
    refute File.exists?(dest_file)
  end

  test "aceita editorial_id de sessao finalizada", %{tmp: tmp} do
    {:ok, editorial} = Capture.start_editorial("Fechado", Path.join(tmp, "ed-c"))
    raw = Path.join(tmp, "closed.CR2")
    File.write!(raw, "c")

    {:ok, photo} =
      Capture.create_photo(%{
        web_path: "/uploads/closed.jpg",
        raw_path: raw
      })

    {:ok, _} = Capture.set_label(photo.id, "host", "host", 4)
    Capture.finish_editorial()

    dest = Path.join(tmp, "out-c")
    assert {:ok, result} = Export.export(dest: dest, editorial_id: editorial.id)
    assert [%{folder: "roxo"}] = result.exported
  end

  test "ignora foto sem label do revisor", %{tmp: tmp} do
    {:ok, _} = Capture.start_editorial("Sem label", Path.join(tmp, "ed-s"))
    raw = Path.join(tmp, "n.CR2")
    File.write!(raw, "n")

    {:ok, photo} = Capture.create_photo(%{web_path: "/uploads/n.jpg", raw_path: raw})

    dest = Path.join(tmp, "out-s")
    assert {:ok, result} = Export.export(dest: dest)
    assert result.exported == []
    assert [%{photo_id: id, reason: :unlabeled}] = result.skipped
    assert id == photo.id
  end
end
