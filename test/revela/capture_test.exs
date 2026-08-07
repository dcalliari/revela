defmodule Revela.CaptureTest do
  use Revela.DataCase, async: true

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

  describe "broadcast_host_viewer" do
    test "nao retransmite quando photo_id/follow/open nao mudam" do
      Capture.reset_host_viewer_state()
      Capture.subscribe_host_viewer()

      Capture.broadcast_host_viewer(%{photo_id: 7, follow: false, open: true})
      assert_receive {:host_viewer, %{photo_id: 7, follow: false, open: true}}

      Capture.broadcast_host_viewer(%{photo_id: 7, follow: false, open: true})
      refute_receive {:host_viewer, _}, 50

      Capture.broadcast_host_viewer(%{photo_id: 8, follow: false, open: true})
      assert_receive {:host_viewer, %{photo_id: 8, follow: false, open: true}}
    end
  end
end
