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

  test "create_brand_share rejeita selecao vazia", %{editorial: editorial} do
    assert {:error, :empty_selection} = Delivery.create_brand_share(editorial.id, [])
  end

  test "google backends ficam stubados", %{editorial: editorial, p1: p1} do
    assert {:error, :not_configured} =
             Delivery.create_brand_share(editorial.id, [p1.id], backend: :google_fotos)

    assert {:error, :not_configured} =
             Delivery.create_brand_share(editorial.id, [p1.id], backend: :google_drive)
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
