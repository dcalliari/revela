defmodule Revela.DeliveryTest do
  use Revela.DataCase, async: false

  alias Revela.{Capture, Delivery}
  alias Revela.Capture.BrandShare

  setup do
    {:ok, editorial} =
      Capture.start_editorial("Entrega", "/tmp/entrega-#{System.unique_integer()}")

    {:ok, p1} = Capture.create_photo(%{web_path: "/uploads/a.jpg"})
    {:ok, p2} = Capture.create_photo(%{web_path: "/uploads/b.jpg"})
    %{editorial: editorial, p1: p1, p2: p2}
  end

  test "create_brand_share local gera token e path", %{editorial: editorial, p1: p1, p2: p2} do
    assert {:ok, share, path} =
             Delivery.create_brand_share(editorial.id, [p1.id, p2.id], label: "intervalo")

    assert path == "/share/#{share.token}"
    assert share.label == "intervalo"
    assert BrandShare.decode_photo_ids(share) == [p1.id, p2.id]
    assert Delivery.get_brand_share(share.token).id == share.id
  end

  test "create_brand_share reusa share quando photo_ids coincidem", %{
    editorial: editorial,
    p1: p1,
    p2: p2
  } do
    assert {:ok, share, path} =
             Delivery.create_brand_share(editorial.id, [p1.id, p2.id], label: "intervalo")

    assert {:ok, same, ^path} =
             Delivery.create_brand_share(editorial.id, [p2.id, p1.id], label: "de novo")

    assert same.id == share.id
    assert same.token == share.token
    assert same.label == "de novo"
    assert length(Capture.list_brand_shares_for_editorial(editorial.id)) == 1
  end

  test "create_brand_share cria novo token quando a selecao muda", %{
    editorial: editorial,
    p1: p1,
    p2: p2
  } do
    assert {:ok, first, _} = Delivery.create_brand_share(editorial.id, [p1.id], label: "a")

    assert {:ok, second, path} =
             Delivery.create_brand_share(editorial.id, [p1.id, p2.id], label: "b")

    assert second.id != first.id
    assert second.token != first.token
    assert path == "/share/#{second.token}"
    assert length(Capture.list_brand_shares_for_editorial(editorial.id)) == 2
  end

  test "create_brand_share reusa share antigo ao oscillar selecao A→B→A", %{
    editorial: editorial,
    p1: p1,
    p2: p2
  } do
    assert {:ok, share_a, path_a} =
             Delivery.create_brand_share(editorial.id, [p1.id], label: "a")

    Capture.set_label(p1.id, "brand-#{share_a.token}", "marca", 1)

    assert {:ok, share_b, _} =
             Delivery.create_brand_share(editorial.id, [p2.id], label: "b")

    assert share_b.id != share_a.id
    assert Capture.brand_labeled_photo_ids(editorial.id) == []

    assert {:ok, reused, ^path_a} =
             Delivery.create_brand_share(editorial.id, [p1.id], label: "a de novo")

    assert reused.id == share_a.id
    assert reused.token == share_a.token
    assert reused.label == "a de novo"
    assert length(Capture.list_brand_shares_for_editorial(editorial.id)) == 2
    assert hd(Capture.list_brand_shares_for_editorial(editorial.id)).id == share_a.id
    assert Capture.brand_labeled_photo_ids(editorial.id) == [p1.id]
  end

  test "create_brand_share atualiza previews ao promover share existente", %{
    editorial: editorial,
    p1: p1,
    p2: p2
  } do
    {:ok, p2} = p2 |> Ecto.Changeset.change(web_path: nil) |> Repo.update()

    assert {:ok, share, _} = Delivery.create_brand_share(editorial.id, [p1.id, p2.id])
    assert BrandShare.decode_photo_ids(share) == [p1.id]

    {:ok, _p2} =
      p2
      |> Ecto.Changeset.change(web_path: "/uploads/b-disponivel.jpg")
      |> Repo.update()

    assert {:ok, promoted, _} = Delivery.create_brand_share(editorial.id, [p2.id, p1.id])
    assert promoted.id == share.id
    assert BrandShare.decode_photo_ids(promoted) == [p1.id, p2.id]
  end

  test "create_brand_share rejeita selecao vazia", %{editorial: editorial} do
    assert {:error, :empty_selection} = Delivery.create_brand_share(editorial.id, [])
  end

  test "google backends ficam stubados", %{editorial: editorial, p1: p1} do
    assert {:error, :not_configured} =
             Delivery.create_brand_share(editorial.id, [p1.id], backend: :google_fotos)

    assert {:error, :not_configured} =
             Delivery.create_brand_share(editorial.id, [p1.id], backend: :google_drive)
  end

  test "limpa artefatos RAW antigos somente ao criar token", %{editorial: editorial, p1: p1} do
    dir = Path.join(System.tmp_dir!(), "revela-raw-root-#{System.unique_integer([:positive])}")
    raw_dir = Path.join(dir, "editorial")
    staging = Path.join(raw_dir, ".raw-pulls")
    orphan = Path.join(staging, "revela-raw-orphan.zip")
    temp = Path.join(staging, "revela-raw-interrompido.zip.tmp")
    work_dir = Path.join(staging, "revela-raw-interrompido")
    File.mkdir_p!(staging)
    File.write!(orphan, "ZIP")
    File.write!(temp, "ZIP incompleto")
    File.mkdir_p!(work_dir)
    File.write!(Path.join(work_dir, "shot.cr2"), "RAW")
    File.touch!(orphan, {{2020, 1, 1}, {0, 0, 0}})
    File.touch!(temp, {{2020, 1, 1}, {0, 0, 0}})
    File.touch!(work_dir, {{2020, 1, 1}, {0, 0, 0}})

    {:ok, raw} =
      Ecto.Changeset.change(p1, raw_path: Path.join(raw_dir, "shot.cr2")) |> Repo.update()

    assert raw.raw_path == Path.join(raw_dir, "shot.cr2")
    assert is_nil(Delivery.get_raw_download("token-invalido"))
    assert File.exists?(orphan)
    assert File.exists?(temp)
    assert File.dir?(work_dir)

    assert {:ok, _download} = Delivery.create_raw_download(editorial.id, [p1.id])
    refute File.exists?(orphan)
    refute File.exists?(temp)
    refute File.exists?(work_dir)
  end

  test "raw_pull separa arquivos presentes e ausentes", %{p1: p1, p2: p2} do
    dir = Path.join(System.tmp_dir!(), "revela-raw-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    raw = Path.join(dir, "shot.cr2")
    File.write!(raw, <<1, 2, 3>>)

    {:ok, p1} =
      p1
      |> Ecto.Changeset.change(%{raw_path: raw})
      |> Repo.update()

    pull = Delivery.raw_pull([p1.id, p2.id])
    assert length(pull.files) == 1
    assert hd(pull.files).path == raw
    assert Enum.map(pull.missing, & &1.id) == [p2.id]
  after
    :ok
  end
end
