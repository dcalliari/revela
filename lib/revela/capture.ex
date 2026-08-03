defmodule Revela.Capture do
  @moduledoc """
  Contexto de captura: fotos que chegam via captura e as classificacoes
  (labels de cor) por revisor. Cada revisor tem o seu proprio conjunto de cores
  para cada foto (classificacao por pessoa).
  """

  import Ecto.Query, warn: false
  alias Revela.Repo
  alias Revela.Capture.{Photo, Label}
  alias Phoenix.PubSub

  @photos_topic "photos"
  @labels_topic "labels"
  @status_topic "capture_status"

  # ── PubSub ────────────────────────────────────────────────────────────────

  def subscribe_photos, do: PubSub.subscribe(Revela.PubSub, @photos_topic)
  def subscribe_labels, do: PubSub.subscribe(Revela.PubSub, @labels_topic)
  def subscribe_status, do: PubSub.subscribe(Revela.PubSub, @status_topic)

  def broadcast_status(status),
    do: PubSub.broadcast(Revela.PubSub, @status_topic, {:capture_status, status})

  defp broadcast_photo(photo),
    do: PubSub.broadcast(Revela.PubSub, @photos_topic, {:new_photo, photo})

  defp broadcast_label(photo_id),
    do: PubSub.broadcast(Revela.PubSub, @labels_topic, {:label_changed, photo_id})

  # ── Fotos ─────────────────────────────────────────────────────────────────

  @doc "Todas as fotos em ordem de captura."
  def list_photos do
    Repo.all(from p in Photo, order_by: [asc: p.seq])
  end

  def get_photo!(id), do: Repo.get!(Photo, id)

  @doc """
  Registra uma foto recem baixada. Calcula o proximo `seq` e transmite o evento
  para todos os LiveViews conectados.
  """
  def create_photo(attrs) do
    seq = (Repo.one(from p in Photo, select: max(p.seq)) || 0) + 1

    %Photo{}
    |> Photo.changeset(Map.put(attrs, :seq, seq))
    |> Repo.insert()
    |> case do
      {:ok, photo} ->
        broadcast_photo(photo)
        {:ok, photo}

      error ->
        error
    end
  end

  # ── Labels (classificacao por revisor) ──────────────────────────────────────

  @doc """
  Limpa a producao atual: apaga todas as labels e fotos do banco e os previews
  web, e avisa os LiveViews conectados para zerarem. Os originais em `captures/`
  NAO sao tocados aqui (arquive-os antes via CameraServer.archive_captures/0).
  """
  def clear_all do
    Repo.delete_all(Label)
    Repo.delete_all(Photo)

    uploads = Application.app_dir(:revela, "priv/static/uploads")

    if File.dir?(uploads) do
      for f <- File.ls!(uploads), do: File.rm(Path.join(uploads, f))
    end

    PubSub.broadcast(Revela.PubSub, @photos_topic, :session_reset)
    :ok
  end

  @doc "Mapa %{photo_id => color} com as cores de um revisor especifico."
  def labels_for_reviewer(reviewer_id) do
    from(l in Label, where: l.reviewer_id == ^reviewer_id, select: {l.photo_id, l.color})
    |> Repo.all()
    |> Map.new()
  end

  @doc "Define/atualiza a cor de uma foto para um revisor."
  def set_label(photo_id, reviewer_id, reviewer_name, color) do
    attrs = %{
      photo_id: photo_id,
      reviewer_id: reviewer_id,
      reviewer_name: reviewer_name,
      color: color
    }

    %Label{}
    |> Label.changeset(attrs)
    |> Repo.insert(
      on_conflict: {:replace, [:color, :reviewer_name, :updated_at]},
      conflict_target: [:photo_id, :reviewer_id]
    )
    |> case do
      {:ok, label} ->
        broadcast_label(photo_id)
        {:ok, label}

      error ->
        error
    end
  end

  @doc "Remove a cor de uma foto para um revisor."
  def clear_label(photo_id, reviewer_id) do
    {count, _} =
      from(l in Label, where: l.photo_id == ^photo_id and l.reviewer_id == ^reviewer_id)
      |> Repo.delete_all()

    if count > 0, do: broadcast_label(photo_id)
    :ok
  end

  @doc """
  Agregacao para a tela do host: mapa %{photo_id => %{color => count}} com a
  contagem de cada cor entre todos os revisores.
  """
  def tallies do
    from(l in Label,
      group_by: [l.photo_id, l.color],
      select: {l.photo_id, l.color, count(l.id)}
    )
    |> Repo.all()
    |> Enum.reduce(%{}, fn {photo_id, color, count}, acc ->
      Map.update(acc, photo_id, %{color => count}, &Map.put(&1, color, count))
    end)
  end
end
