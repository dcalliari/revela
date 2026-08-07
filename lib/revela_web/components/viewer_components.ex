defmodule RevelaWeb.ViewerComponents do
  @moduledoc """
  Visualizador imersivo (tela cheia preta) compartilhado pela tela de revisao
  (celular) e pela tela do host. Os eventos (`pick`, `clear`, `prev`, `next`,
  `go_live`, `close`, `key`) sao tratados pelo LiveView que renderiza o componente.

  O rodape expoe a legenda `#shortcuts-legend` (`1`–`5` cores, `0` limpar,
  setas, `L` ao vivo) e numeros nas bolinhas; o mapeamento das teclas vive em
  `HostLive` / `ReviewLive`.

  No celular, o container `#zoomer` (ou `zoom_id`) usa o hook JS `PinchZoom`
  (focal pinch, pan com zoom > 1, toque duplo reseta). Nao fixe
  `transform-origin: center` no `<img>` — a origem fica em `0 0` via JS.
  """
  use RevelaWeb, :html

  alias RevelaWeb.Colors

  attr :photo, :map, default: nil
  attr :count, :integer, required: true
  attr :idx, :integer, required: true
  attr :follow, :boolean, required: true
  attr :labels, :map, required: true
  attr :title, :string, default: ""
  attr :zoom_id, :string, default: "zoomer"
  attr :fs_id, :string, default: "fs-btn"
  attr :closable, :boolean, default: false
  # Host ja liga phx-window-keyup na pagina; evita disparo duplo de teclas.
  attr :window_keys, :boolean, default: true

  def viewer(assigns) do
    ~H"""
    <div
      class="fixed inset-0 z-50 flex flex-col bg-black text-white select-none touch-manipulation"
      phx-window-keyup={if(@window_keys, do: "key")}
    >
      <header class="flex items-center justify-between px-4 py-2 text-sm bg-neutral-900">
        <span class="font-medium truncate">{@title}</span>
        <div class="flex items-center gap-3">
          <span :if={@count > 0} class="tabular-nums opacity-70">
            {@idx + 1} / {@count}
          </span>
          <button
            phx-click="go_live"
            class={[
              "px-2 py-1 rounded text-xs font-semibold",
              @follow && "bg-red-600 text-white",
              !@follow && "bg-neutral-700 text-neutral-200"
            ]}
          >
            {if @follow, do: "AO VIVO", else: "ir ao vivo"}
          </button>
          <button
            id={@fs_id}
            phx-hook="Fullscreen"
            aria-label="Tela cheia"
            class="px-2 py-1 rounded text-xs bg-neutral-700 text-neutral-200"
          >
            ⛶
          </button>
          <button
            :if={@closable}
            phx-click="close"
            aria-label="Fechar"
            class="px-2 py-1 rounded text-xs bg-neutral-700 text-neutral-200"
          >
            ✕
          </button>
        </div>
      </header>

      <main class="flex-1 relative flex items-center justify-center overflow-hidden">
        <div :if={@count == 0} class="text-center opacity-60 animate-pulse">
          <p class="text-lg">Aguardando a primeira foto...</p>
          <p class="text-sm mt-1">Dispare na camera para comecar.</p>
        </div>

        <div
          :if={@photo}
          id={@zoom_id}
          phx-hook="PinchZoom"
          class="absolute inset-0 flex items-center justify-center overflow-hidden touch-none"
        >
          <img
            src={@photo.web_path}
            class="max-h-full max-w-full object-contain will-change-transform"
            draggable="false"
          />
        </div>

        <button
          :if={@photo && @idx > 0}
          phx-click="prev"
          aria-label="Foto anterior"
          class="absolute left-0 top-0 h-full w-1/3 flex items-center justify-start pl-3 text-5xl text-white/40 active:text-white/90 z-10 touch-manipulation"
        >
          &lsaquo;
        </button>
        <button
          :if={@photo && @idx < @count - 1}
          phx-click="next"
          aria-label="Proxima foto"
          class="absolute right-0 top-0 h-full w-1/3 flex items-center justify-end pr-3 text-5xl text-white/40 active:text-white/90 z-10 touch-manipulation"
        >
          &rsaquo;
        </button>
      </main>

      <footer :if={@photo} class="bg-neutral-900 px-3 pt-3 pb-6">
        <div class="flex items-center justify-center gap-3">
          <button
            :for={color <- Colors.all()}
            phx-click="pick"
            phx-value-color={color.value}
            aria-label={"#{color.name} (#{color.value + 1})"}
            class={[
              "relative h-12 w-12 rounded-full transition-transform active:scale-90 ring-offset-2 ring-offset-neutral-900 touch-manipulation",
              @labels[@photo.id] == color.value && "ring-4 ring-white scale-110",
              @labels[@photo.id] != color.value && "ring-0 opacity-80"
            ]}
            style={"background-color: #{color.hex}"}
          >
            <span class="absolute inset-0 flex items-center justify-center text-[11px] font-semibold text-white/90 drop-shadow-[0_1px_1px_rgba(0,0,0,0.8)] pointer-events-none">
              {color.value + 1}
            </span>
          </button>
          <button
            phx-click="clear"
            aria-label="Limpar cor (0)"
            class="relative h-12 w-12 rounded-full border-2 border-neutral-600 text-neutral-400 flex items-center justify-center active:scale-90 touch-manipulation"
          >
            <span class="text-[11px] font-semibold opacity-70">0</span>
          </button>
        </div>
        <p
          id="shortcuts-legend"
          class="mt-2.5 text-center text-[10px] leading-relaxed tracking-wide text-neutral-500"
        >
          <span class="tabular-nums">1–5</span>
          cores · <span class="tabular-nums">0</span>
          limpar · ← → · <kbd class="font-sans">L</kbd>
          ao vivo
        </p>
      </footer>
    </div>
    """
  end
end
