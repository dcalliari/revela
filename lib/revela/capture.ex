defmodule Revela.Capture do
  @moduledoc """
  Contexto de captura: editoriais (sessoes de revisao), fotos e classificacoes
  (labels de cor) por revisor. Fotos e labels pertencem ao editorial ativo no
  momento da captura; iniciar/finalizar um editorial nao apaga dados — so troca
  qual sessao esta ativa. Sem editorial ativo, listagens ficam vazias (fotos com
  `editorial_id` nulo nao entram na UI). Cada revisor tem o seu proprio conjunto
  de cores para cada foto (classificacao por pessoa).

  Tambem publica o estado do visualizador do Host (`broadcast_host_viewer/1`)
  para `TvLive` (`/tv`); start/finish de editorial zera esse estado.
  """

  import Ecto.Query, warn: false
  alias Revela.Repo
  alias Revela.Capture.{Photo, Label, Editorial}
  alias Phoenix.PubSub

  @photos_topic "photos"
  @labels_topic "labels"
  @status_topic "capture_status"
  alias Revela.Capture.HostViewerState

  @host_viewer_topic "host_viewer"
  @host_registry __MODULE__.HostRegistry
  @host_registry_key :host
  @default_host_viewer HostViewerState.default()

  # ── PubSub ────────────────────────────────────────────────────────────────

  def subscribe_photos, do: PubSub.subscribe(Revela.PubSub, @photos_topic)
  def subscribe_labels, do: PubSub.subscribe(Revela.PubSub, @labels_topic)
  def subscribe_status, do: PubSub.subscribe(Revela.PubSub, @status_topic)
  def subscribe_host_viewer, do: PubSub.subscribe(Revela.PubSub, @host_viewer_topic)

  def broadcast_status(status),
    do: PubSub.broadcast(Revela.PubSub, @status_topic, {:capture_status, status})

  @doc """
  Registra o processo `HostLive` atual como Host presente. O Registry remove
  a entrada automaticamente quando o processo morre (aba fechada, crash,
  queda de rede) — nao depende de `terminate/2` nem de um broadcast
  `open: false`.
  """
  def track_host do
    case Registry.register(@host_registry, @host_registry_key, true) do
      {:ok, _} -> :ok
      {:error, {:already_registered, _}} -> :ok
    end
  end

  @doc "True se pelo menos um `HostLive` conectado ainda esta vivo."
  def host_present? do
    Registry.lookup(@host_registry, @host_registry_key) != []
  end

  @doc """
  Publica o estado do visualizador do Host para a superficie `/tv`.
  Mantem o ultimo estado (slot unico, nao por conexao — uma segunda aba do
  Host sobrescreve; ver AGENTS.md "Domain: TV presentation (`/tv`)") para
  LiveViews que entram no meio da sessao. Deduplica: estado igual ao ja
  persistido nao gera novo evento PubSub, entao consumidores que precisam
  resincronizar sem depender de uma mudanca real devem ler
  `host_viewer_mirror_state/0` direto em vez de esperar por um broadcast.
  """
  def broadcast_host_viewer(state) when is_map(state) do
    normalized = %{
      photo_id: Map.get(state, :photo_id),
      follow: Map.get(state, :follow, true) == true,
      open: Map.get(state, :open, false) == true
    }

    if host_viewer_state() == normalized do
      :ok
    else
      HostViewerState.put(normalized)
      PubSub.broadcast(Revela.PubSub, @host_viewer_topic, {:host_viewer, normalized})
      :ok
    end
  end

  @doc "Ultimo estado bruto do visualizador do Host (ou follow ao vivo se ainda nao houve broadcast)."
  def host_viewer_state do
    HostViewerState.get()
  end

  @doc """
  Estado do Host para espelhamento pela TV. Sem Host vivo, trata como viewer
  fechado (ao vivo) — o slot pode ficar com `open: true` apos crash/queda sem
  anuncio.
  """
  def host_viewer_mirror_state do
    if host_present?() do
      host_viewer_state()
    else
      @default_host_viewer
    end
  end

  @doc false
  def reset_host_viewer_state do
    HostViewerState.reset()
    :ok
  end

  defp broadcast_photo(photo),
    do: PubSub.broadcast(Revela.PubSub, @photos_topic, {:new_photo, photo})

  @doc false
  def broadcast_photo_update(photo), do: broadcast_photo(photo)

  defp broadcast_label(photo_id),
    do: PubSub.broadcast(Revela.PubSub, @labels_topic, {:label_changed, photo_id})

  defp broadcast_brand_round(editorial_id),
    do: PubSub.broadcast(Revela.PubSub, @labels_topic, {:brand_round_changed, editorial_id})

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
    opts
    |> Keyword.take([:colors])
    |> photos_query()
    |> Repo.aggregate(:count)
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
    brand_scope = brand_label_scope(current_editorial_id())

    from(p in query,
      where:
        exists(
          from(l in Label,
            where: l.photo_id == parent_as(:photo).id and l.color in ^colors,
            where: ^brand_scope,
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

    attrs =
      attrs
      |> Map.put(:seq, seq)
      |> Map.put_new(:editorial_id, current_editorial_id())

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

  @doc """
  Fotos com `raw_path` nulo ou vazio, ordenadas por id.

  Opcoes:
  - `:dir` — restringe a `original_path` cujo diretorio e exatamente este
    (prefixo `dir/` via LIKE), para o hot path de `attach_raw/1`.
  """
  def list_photos_missing_raw(opts \\ []) do
    dir = Keyword.get(opts, :dir)

    from(p in Photo,
      where: is_nil(p.raw_path) or p.raw_path == "",
      order_by: [asc: p.id]
    )
    |> maybe_scope_missing_raw_to_dir(dir)
    |> Repo.all()
  end

  defp maybe_scope_missing_raw_to_dir(query, nil), do: query

  defp maybe_scope_missing_raw_to_dir(query, dir) when is_binary(dir) and dir != "" do
    pattern = like_dir_prefix(dir)
    escape = "\\"
    from(p in query, where: fragment("? LIKE ? ESCAPE ?", p.original_path, ^pattern, ^escape))
  end

  defp like_dir_prefix(dir) do
    dir
    |> String.replace("\\", "\\\\")
    |> String.replace("%", "\\%")
    |> String.replace("_", "\\_")
    |> Kernel.<>("/%")
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

  @doc "Limpa o caminho do JPEG original apos o arquivo ser removido com sucesso."
  def clear_original_path(%Photo{} = photo) do
    now = DateTime.utc_now(:microsecond)

    case Repo.update_all(from(p in Photo, where: p.id == ^photo.id),
           set: [original_path: nil, updated_at: now]
         ) do
      {1, _} -> {:ok, %{photo | original_path: nil, updated_at: now}}
      {0, _} -> {:error, :photo_not_found}
    end
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
          current = get_photo!(photo.id)

          if current.raw_path == raw_path do
            {:ok, current}
          else
            {:error, :already_has_other_raw}
          end
      end
    rescue
      e in [Ecto.ConstraintError, Exqlite.Error] ->
        {:error, e}
    end
  end

  defp present_raw_path?(path), do: is_binary(path) and path != ""

  @doc """
  Importa uma pasta de fotos do cartao (JPEG/RAW) para o editorial ativo.
  Ver `Revela.Capture.CardImport`.
  """
  def import_from_folder(source_dir, opts \\ []) do
    Revela.Capture.CardImport.import_folder(source_dir, opts)
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
        reset_host_viewer_state()
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
    reset_host_viewer_state()
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

  @doc "Editorial por id, ou nil."
  def get_editorial(id) when is_integer(id), do: Repo.get(Editorial, id)
  def get_editorial(_), do: nil

  @doc "Todos os editoriais, mais recentes primeiro (ativos e finalizados)."
  def list_editorials do
    from(e in Editorial, order_by: [desc: e.started_at])
    |> Repo.all()
  end

  @doc "Mapa %{photo_id => color} de um revisor num editorial (ativo ou nao)."
  def labels_for_reviewer_in_editorial(reviewer_id, editorial_id) do
    from(l in Label,
      join: p in Photo,
      on: p.id == l.photo_id,
      where: l.reviewer_id == ^reviewer_id and p.editorial_id == ^editorial_id,
      select: {l.photo_id, l.color}
    )
    |> Repo.all()
    |> Map.new()
  end

  @doc """
  Agregacao de cores para um editorial especifico.

  Labels `brand-*` so entram do BrandShare mais recente (mesmo criterio de
  `brand_labeled_photo_ids/1`); shares supersedidos nao aparecem na grade Post.
  """
  def tallies_for_editorial(editorial_id) do
    brand_scope = brand_label_scope(editorial_id)

    from(l in Label,
      join: p in Photo,
      on: p.id == l.photo_id,
      where: p.editorial_id == ^editorial_id,
      where: ^brand_scope,
      group_by: [l.photo_id, l.color],
      select: {l.photo_id, l.color, count(l.id)}
    )
    |> Repo.all()
    |> Enum.reduce(%{}, fn {photo_id, color, count}, acc ->
      Map.update(acc, photo_id, %{color => count}, &Map.put(&1, color, count))
    end)
  end

  @doc """
  IDs de fotos marcadas no BrandShare mais recente deste editorial
  (`brand-<token>`), em ordem de captura (`seq`). Shares antigos nao entram.
  """
  def brand_labeled_photo_ids(editorial_id) do
    case list_brand_shares_for_editorial(editorial_id) do
      [] ->
        []

      [%BrandShare{token: token} | _] ->
        reviewer_id = "brand-#{token}"

        from(p in Photo,
          join: l in Label,
          on: l.photo_id == p.id,
          where: p.editorial_id == ^editorial_id,
          where: l.reviewer_id == ^reviewer_id,
          order_by: [asc: p.seq],
          select: p.id
        )
        |> Repo.all()
    end
  end

  # ── Brand shares (URL de previews para a marca) ─────────────────────────────

  def create_brand_share(attrs) do
    case %BrandShare{} |> BrandShare.changeset(attrs) |> Repo.insert() do
      {:ok, share} = result ->
        broadcast_brand_round(share.editorial_id)
        result

      error ->
        error
    end
  end

  def touch_brand_share(%BrandShare{} = share, opts \\ []) when is_list(opts) do
    changes = %{updated_at: DateTime.utc_now(:microsecond)}

    changes =
      if Keyword.has_key?(opts, :label) do
        Map.put(changes, :label, Keyword.get(opts, :label))
      else
        changes
      end

    case share |> Ecto.Changeset.change(changes) |> Repo.update() do
      {:ok, touched} = result ->
        broadcast_brand_round(touched.editorial_id)
        result

      error ->
        error
    end
  end

  def get_brand_share_by_token(token) when is_binary(token) do
    Repo.get_by(BrandShare, token: token)
  end

  def list_brand_shares_for_editorial(editorial_id) do
    from(s in BrandShare,
      where: s.editorial_id == ^editorial_id,
      order_by: [desc: s.updated_at, desc: s.id]
    )
    |> Repo.all()
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

  Labels `brand-*` seguem o mesmo criterio de `tallies_for_editorial/1`:
  so o BrandShare mais recente conta.
  """
  def tallies do
    brand_scope =
      case current_editorial_id() do
        nil -> dynamic([l], true)
        editorial_id -> brand_label_scope(editorial_id)
      end

    from(l in Label,
      join: p in Photo,
      as: :photo,
      on: p.id == l.photo_id,
      where: ^editorial_scope(),
      where: ^brand_scope,
      group_by: [l.photo_id, l.color],
      select: {l.photo_id, l.color, count(l.id)}
    )
    |> Repo.all()
    |> Enum.reduce(%{}, fn {photo_id, color, count}, acc ->
      Map.update(acc, photo_id, %{color => count}, &Map.put(&1, color, count))
    end)
  end

  defp brand_label_scope(editorial_id) do
    case list_brand_shares_for_editorial(editorial_id) do
      [%BrandShare{token: token} | _] ->
        latest = "brand-#{token}"
        dynamic([l], not like(l.reviewer_id, "brand-%") or l.reviewer_id == ^latest)

      [] ->
        dynamic([l], not like(l.reviewer_id, "brand-%"))
    end
  end
end
