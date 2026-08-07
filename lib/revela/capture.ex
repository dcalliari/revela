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

  @doc """
  Fotos do editorial atual. Vazio se nao ha editorial ativo.

  Opcoes:

    * `:order` — `:asc` (padrao, ordem de captura) ou `:desc` (mais recentes primeiro)
    * `:limit` / `:offset` — paginacao no banco
    * `:colors` — lista de cores (0..4); retorna fotos com ao menos um label em
      qualquer dessas cores. Lista vazia ou omitida = sem filtro de cor.
  """
  def list_photos(opts \\ []) when is_list(opts) do
    opts
    |> photos_query()
    |> Repo.all()
  end

  @doc """
  Contagem de fotos do editorial atual, com o mesmo filtro de `:colors` de
  `list_photos/1`. Usada pela paginacao da grade do host.
  """
  def count_photos(opts \\ []) when is_list(opts) do
    colors = normalize_colors(Keyword.get(opts, :colors))

    from(p in Photo, as: :photo, where: ^editorial_scope(), select: count(p.id))
    |> apply_color_filter(colors)
    |> Repo.one()
  end

  def get_photo!(id), do: Repo.get!(Photo, id)

  defp photos_query(opts) do
    colors = normalize_colors(Keyword.get(opts, :colors))
    order = Keyword.get(opts, :order, :asc)
    limit = Keyword.get(opts, :limit)
    offset = Keyword.get(opts, :offset, 0)

    from(p in Photo, as: :photo, where: ^editorial_scope())
    |> apply_color_filter(colors)
    |> order_photos(order)
    |> maybe_limit(limit)
    |> maybe_offset(offset)
  end

  defp order_photos(query, :desc), do: order_by(query, [p], desc: p.seq)
  defp order_photos(query, _), do: order_by(query, [p], asc: p.seq)

  defp maybe_limit(query, nil), do: query
  defp maybe_limit(query, limit) when is_integer(limit) and limit >= 0, do: limit(query, ^limit)

  defp maybe_offset(query, offset) when is_integer(offset) and offset > 0,
    do: offset(query, ^offset)

  defp maybe_offset(query, _), do: query

  defp normalize_colors(nil), do: []

  defp normalize_colors(colors) when is_list(colors) do
    colors
    |> Enum.map(fn
      c when is_integer(c) -> c
      c when is_binary(c) -> String.to_integer(c)
    end)
    |> Enum.filter(&(&1 in 0..4))
    |> Enum.uniq()
  end

  defp apply_color_filter(query, []), do: query

  defp apply_color_filter(query, colors) do
    from(p in query,
      where:
        exists(
          from(l in Label,
            where: l.photo_id == parent_as(:photo).id and l.color in ^colors,
            select: 1
          )
        )
    )
  end

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
