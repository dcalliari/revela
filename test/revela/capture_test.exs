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
      assert Capture.labels_for_reviewer("host") == %{}
      assert is_nil(Capture.current_editorial_id())
    end
  end
end
