defmodule Revela.CaptureTest do
  use Revela.DataCase, async: false

  alias Revela.Capture

  describe "editorial lifecycle preserva classificacoes" do
    test "iniciar um novo editorial nao apaga as classificacoes do editorial anterior" do
      {:ok, editorial_a} = Capture.start_editorial("Casamento A", "/tmp/casamento-a")
      {:ok, photo} = Capture.create_photo(%{web_path: "/uploads/1.jpg"})
      {:ok, _label} = Capture.set_label(photo.id, "host", "host", 2)

      assert Capture.tallies() == %{photo.id => %{2 => 1}}
      assert Capture.labels_for_reviewer("host") == %{photo.id => 2}

      {:ok, _editorial_b} = Capture.start_editorial("Casamento B", "/tmp/casamento-b")

      assert Repo.aggregate(Revela.Capture.Label, :count) == 1
      assert Repo.aggregate(Revela.Capture.Photo, :count) == 1
      assert Repo.get(Revela.Capture.Photo, photo.id)

      # a tela do editorial novo comeca vazia, mas nada foi apagado do banco
      assert Capture.list_photos() == []
      assert Capture.labels_for_reviewer("host") == %{}
      assert Capture.tallies() == %{}

      refute editorial_a.id == Capture.current_editorial_id()
    end

    test "finalizar o editorial nao apaga as classificacoes" do
      {:ok, _editorial} = Capture.start_editorial("Formatura", "/tmp/formatura")
      {:ok, photo} = Capture.create_photo(%{web_path: "/uploads/2.jpg"})
      {:ok, _label} = Capture.set_label(photo.id, "host", "host", 0)

      Capture.finish_editorial()

      assert Repo.aggregate(Revela.Capture.Label, :count) == 1
      assert Repo.aggregate(Revela.Capture.Photo, :count) == 1
      assert Capture.list_photos() == []
      assert Capture.labels_for_reviewer("host") == %{}
      assert Capture.tallies() == %{}
      assert is_nil(Capture.current_editorial_id())
    end

    test "sem editorial ativo nao lista fotos com editorial_id nulo" do
      {:ok, limbo} =
        %Revela.Capture.Photo{}
        |> Revela.Capture.Photo.changeset(%{web_path: "/uploads/limbo.jpg", seq: 1})
        |> Repo.insert()

      assert is_nil(limbo.editorial_id)
      assert Capture.list_photos() == []
      assert Capture.labels_for_reviewer("host") == %{}
      assert Capture.tallies() == %{}
    end

    test "indice impede mais de um editorial ativo" do
      {:ok, _} = Capture.start_editorial("Um", "/tmp/um")

      assert {:error, %Ecto.Changeset{}} =
               %Revela.Capture.Editorial{}
               |> Revela.Capture.Editorial.changeset(%{
                 name: "Dois",
                 folder: "/tmp/dois",
                 started_at: DateTime.utc_now()
               })
               |> Repo.insert()
    end
  end

  describe "paginacao e filtro por cor" do
    setup do
      {:ok, _editorial} = Capture.start_editorial("Grade", "/tmp/grade")

      photos =
        for i <- 1..30 do
          {:ok, photo} = Capture.create_photo(%{web_path: "/uploads/#{i}.jpg"})
          photo
        end

      %{photos: photos}
    end

    test "list_photos pagina com limit/offset e ordem desc", %{photos: photos} do
      newest = List.last(photos)
      oldest = hd(photos)

      page1 = Capture.list_photos(order: :desc, limit: 24, offset: 0)
      assert length(page1) == 24
      assert hd(page1).id == newest.id
      refute Enum.any?(page1, &(&1.id == oldest.id))

      page2 = Capture.list_photos(order: :desc, limit: 24, offset: 24)
      assert length(page2) == 6
      assert List.last(page2).id == oldest.id

      assert Capture.count_photos() == 30
      assert Capture.list_photos(order: :desc, limit: 24, offset: 30) == []
    end

    test "filtro por cor roda no banco e combina com paginacao", %{photos: photos} do
      [p1, p2, p3 | _] = photos

      {:ok, _} = Capture.set_label(p1.id, "a", "Ana", 0)
      {:ok, _} = Capture.set_label(p2.id, "a", "Ana", 2)
      {:ok, _} = Capture.set_label(p3.id, "b", "Bia", 0)

      reds = Capture.list_photos(colors: [0], order: :asc)
      assert Enum.map(reds, & &1.id) == [p1.id, p3.id]
      assert Capture.count_photos(colors: [0]) == 2

      multi = Capture.list_photos(colors: [0, 2], order: :asc)
      assert Enum.map(multi, & &1.id) == [p1.id, p2.id, p3.id]
      assert Capture.count_photos(colors: [0, 2]) == 3

      assert Capture.list_photos(colors: [4]) == []
      assert Capture.count_photos(colors: [4]) == 0

      # sem filtro continua listando todas
      assert Capture.count_photos(colors: []) == 30
      assert length(Capture.list_photos()) == 30

      paged = Capture.list_photos(colors: [0], order: :desc, limit: 1, offset: 0)
      assert length(paged) == 1
      assert hd(paged).id == p3.id
    end
  end

  describe "tallies_for_editorial/1" do
    test "ignora votos brand-* de shares supersedidos" do
      {:ok, editorial} = Capture.start_editorial("Tallies", "/tmp/tallies-#{System.unique_integer()}")
      {:ok, a} = Capture.create_photo(%{web_path: "/uploads/tally-a.jpg"})
      {:ok, b} = Capture.create_photo(%{web_path: "/uploads/tally-b.jpg"})

      {:ok, old_share, _} = Delivery.create_brand_share(editorial.id, [a.id], label: "velho")
      Capture.set_label(a.id, "brand-#{old_share.token}", "marca", 1)

      {:ok, share, _} = Delivery.create_brand_share(editorial.id, [b.id], label: "novo")
      Capture.set_label(b.id, "brand-#{share.token}", "marca", 2)
      Capture.set_label(a.id, "host", "host", 0)

      tallies = Capture.tallies_for_editorial(editorial.id)

      # host color 0 only — brand color 1 from superseded share must not appear
      assert tallies[a.id] == %{0 => 1}
      assert tallies[b.id] == %{2 => 1}
    end
  end
end
