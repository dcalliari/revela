defmodule Revela.Capture do
  @moduledoc """
  Contexto de captura: editoriais (sessoes de revisao), fotos e classificacoes
  (labels de cor) por revisor. Fotos e labels pertencem ao editorial ativo no
  momento da captura; iniciar/finalizar um editorial nao apaga dados — so troca
  qual sessao esta ativa. Sem editorial ativo, listagens ficam vazias (fotos com
  `editorial_id` nulo nao entram na UI). Cada revisor tem o seu proprio conjunto
  de cores para cada foto (classificacao por pessoa).
  """

  import Ecto.Query, warn: false
  alias Revela.Repo
  alias Revela.Capture.{Photo, Label, Editorial}
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

  @doc "Fotos do editorial atual, em ordem de captura. Vazio se nao ha editorial ativo."
  def list_photos do
    from(p in Photo, as: :photo, where: ^editorial_scope(), order_by: [asc: p.seq])
    |> Repo.all()
  end

  def get_photo!(id), do: Repo.get!(Photo, id)

  @doc """
  Registra uma foto recem baixada, associada ao editorial ativo (se houver).
  Calcula o proximo `seq` e transmite o evento para todos os LiveViews conectados.
  """
  def create_photo(attrs) do
    seq = (Repo.one(from p in Photo, select: max(p.seq)) || 0) + 1
    attrs = attrs |> Map.put(:seq, seq) |> Map.put(:editorial_id, current_editorial_id())

    %Photo{}
    |> Photo.changeset(attrs)
    |> Repo.insert()
    |> case do
      {:ok, photo} ->
        broadcast_photo(photo)
        {:ok, photo}

      error ->
        error
    end
  end

  @doc "Fotos com `raw_path` nulo ou vazio (qualquer editorial), ordenadas por id."
  def list_photos_missing_raw do
    from(p in Photo,
      where: is_nil(p.raw_path) or p.raw_path == "",
      order_by: [asc: p.id]
    )
    |> Repo.all()
  end

  @doc "Conjunto de caminhos RAW ja associados a alguma foto."
  def claimed_raw_paths do
    from(p in Photo,
      where: not is_nil(p.raw_path) and p.raw_path != "",
      select: p.raw_path
    )
    |> Repo.all()
    |> MapSet.new()
  end

  @doc """
  Preenche `raw_path` de uma foto que ainda nao tem RAW associado.
  Nao sobrescreve um `raw_path` ja preenchido. Usa UPDATE condicional e o indice
  unico parcial em `raw_path` nao-vazio para impedir o mesmo RAW em duas fotos.
  """
  def update_raw_path(%Photo{} = photo, raw_path) when is_binary(raw_path) and raw_path != "" do
    if present_raw_path?(photo.raw_path) do
      {:ok, photo}
    else
      claim_raw_path(photo, raw_path)
    end
  end

  defp claim_raw_path(%Photo{} = photo, raw_path) do
    now = DateTime.utc_now(:microsecond)

    query =
      from(p in Photo,
        where: p.id == ^photo.id and (is_nil(p.raw_path) or p.raw_path == "")
      )

    try do
      case Repo.update_all(query, set: [raw_path: raw_path, updated_at: now]) do
        {1, _} ->
          {:ok, %{photo | raw_path: raw_path, updated_at: now}}

        {0, _} ->
          {:ok, get_photo!(photo.id)}
      end
    rescue
      e in [Ecto.ConstraintError, Exqlite.Error] ->
        {:error, e}
    end
  end

  defp present_raw_path?(path), do: is_binary(path) and path != ""

  # ── Editoriais ───────────────────────────────────────────────────────────────

  @doc """
  Inicia um novo editorial. Finaliza o editorial ativo, se houver, sem apagar
  nenhuma foto ou classificacao: cada editorial permanece no banco, associado
  as suas proprias fotos e labels, para sempre poder ser consultado depois.
  Avisa os LiveViews conectados para trocarem a tela para o editorial novo.
  """
  def start_editorial(name, folder) do
    Repo.transaction(fn ->
      finish_active_editorial()

      %Editorial{}
      |> Editorial.changeset(%{name: name, folder: folder, started_at: DateTime.utc_now()})
      |> Repo.insert()
      |> case do
        {:ok, editorial} -> editorial
        {:error, changeset} -> Repo.rollback(changeset)
      end
    end)
    |> case do
      {:ok, editorial} ->
        PubSub.broadcast(Revela.PubSub, @photos_topic, :session_reset)
        {:ok, editorial}

      error ->
        error
    end
  end

  @doc """
  Finaliza o editorial ativo (se houver): marca `finished_at`, sem apagar
  fotos ou classificacoes. Volta a tela para o estado "sem editorial".
  """
  def finish_editorial do
    finish_active_editorial()
    PubSub.broadcast(Revela.PubSub, @photos_topic, :session_reset)
    :ok
  end

  @doc "Editorial ativo (finished_at nulo), ou nil se nao ha um."
  def current_editorial do
    Repo.one(from e in Editorial, where: is_nil(e.finished_at), limit: 1)
  end

  @doc "Id do editorial ativo (finished_at nulo), ou nil se nao ha um."
  def current_editorial_id do
    case current_editorial() do
      %{id: id} -> id
      nil -> nil
    end
  end

  defp finish_active_editorial do
    from(e in Editorial, where: is_nil(e.finished_at))
    |> Repo.update_all(set: [finished_at: DateTime.utc_now()])
  end

  defp editorial_scope do
    case current_editorial_id() do
      nil -> dynamic([photo: _p], false)
      id -> dynamic([photo: p], p.editorial_id == ^id)
    end
  end

  # ── Labels (classificacao por revisor) ──────────────────────────────────────

  @doc "Mapa %{photo_id => color} com as cores de um revisor especifico, no editorial atual."
  def labels_for_reviewer(reviewer_id) do
    from(l in Label,
      join: p in Photo,
      as: :photo,
      on: p.id == l.photo_id,
      where: l.reviewer_id == ^reviewer_id,
      where: ^editorial_scope(),
      select: {l.photo_id, l.color}
    )
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
  Agregacao para a tela do host no editorial atual: mapa
  `%{photo_id => %{color => count}}` com a contagem de cada cor entre todos os
  revisores. Vazio se nao ha editorial ativo.
  """
  def tallies do
    from(l in Label,
      join: p in Photo,
      as: :photo,
      on: p.id == l.photo_id,
      where: ^editorial_scope(),
      group_by: [l.photo_id, l.color],
      select: {l.photo_id, l.color, count(l.id)}
    )
    |> Repo.all()
    |> Enum.reduce(%{}, fn {photo_id, color, count}, acc ->
      Map.update(acc, photo_id, %{color => count}, &Map.put(&1, color, count))
    end)
  end
end
