// If you want to use Phoenix channels, run `mix help phx.gen.channel`
// to get started and then uncomment the line below.
// import "./user_socket.js"

// You can include dependencies in two ways.
//
// The simplest option is to put them in assets/vendor and
// import them using relative paths:
//
//     import "../vendor/some-package.js"
//
// Alternatively, you can `npm install some-package --prefix assets` and import
// them using a path starting with the package name:
//
//     import "some-package"
//
// If you have dependencies that try to import CSS, esbuild will generate a separate `app.css` file.
// To load it, simply add a second `<link>` to your `root.html.heex` file.

// Include phoenix_html to handle method=PUT/DELETE in forms and buttons.
import "phoenix_html"
// Establish Phoenix Socket and LiveView configuration.
import {Socket} from "phoenix"
import {LiveSocket} from "phoenix_live_view"
import {hooks as colocatedHooks} from "phoenix-colocated/revela"
import topbar from "../vendor/topbar"

const csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content")

// Identidade leve do revisor: um id estavel guardado no proprio dispositivo,
// enviado ao LiveView via params de conexao. Sem login, adequado a uma LAN de estudio.
// id sem depender de crypto.randomUUID (indisponivel em http:// na LAN, que nao
// e "secure context"); funciona igual no celular acessando por IP.
function genReviewerId() {
  try {
    if (window.crypto && crypto.randomUUID) return crypto.randomUUID()
  } catch (_e) {}
  return "r-" + Date.now().toString(36) + "-" + Math.random().toString(36).slice(2, 10)
}

const Hooks = {
  Identity: {
    mounted() {
      this.el.addEventListener("submit", e => {
        e.preventDefault()
        const name = this.el.querySelector("input[name=name]").value.trim()
        if (!name) return
        const id = localStorage.getItem("reviewer_id") || genReviewerId()
        localStorage.setItem("reviewer_id", id)
        localStorage.setItem("reviewer_name", name)
        window.location.reload()
      })
    }
  },

  // pinch-to-zoom + arrastar na foto (celular). Duplo toque reseta.
  PinchZoom: {
    mounted() {
      const s = {scale: 1, tx: 0, ty: 0, startDist: 0, startScale: 1, panStart: null, lastTap: 0}
      const img = () => this.el.querySelector("img")
      const apply = () => {
        const im = img()
        if (im) im.style.transform = `translate(${s.tx}px, ${s.ty}px) scale(${s.scale})`
      }
      const reset = () => { s.scale = 1; s.tx = 0; s.ty = 0; apply() }
      const dist = t => Math.hypot(t[0].clientX - t[1].clientX, t[0].clientY - t[1].clientY)
      this.resetZoom = reset

      this.el.addEventListener("touchstart", e => {
        if (e.touches.length === 2) {
          s.startDist = dist(e.touches) || 1
          s.startScale = s.scale
        } else if (e.touches.length === 1 && s.scale > 1) {
          s.panStart = {x: e.touches[0].clientX - s.tx, y: e.touches[0].clientY - s.ty}
        }
      }, {passive: false})

      this.el.addEventListener("touchmove", e => {
        if (e.touches.length === 2) {
          e.preventDefault()
          s.scale = Math.min(Math.max(s.startScale * dist(e.touches) / s.startDist, 1), 5)
          apply()
        } else if (e.touches.length === 1 && s.scale > 1 && s.panStart) {
          e.preventDefault()
          s.tx = e.touches[0].clientX - s.panStart.x
          s.ty = e.touches[0].clientY - s.panStart.y
          apply()
        }
      }, {passive: false})

      this.el.addEventListener("touchend", e => {
        if (s.scale <= 1) reset()
        const now = Date.now()
        if (e.touches.length === 0 && now - s.lastTap < 300) reset()
        s.lastTap = now
        s.panStart = null
      })
    },
    updated() { if (this.resetZoom) this.resetZoom() }
  },

  // alterna a tela cheia. Safari no iPhone nao tem Fullscreen API: nesse caso,
  // orienta a instalar como PWA (Adicionar a Tela de Inicio), que abre sem a barra.
  Fullscreen: {
    mounted() {
      this.el.addEventListener("click", () => {
        const el = document.documentElement
        if (document.fullscreenElement) {
          document.exitFullscreen()
        } else if (el.requestFullscreen) {
          el.requestFullscreen().catch(() => {})
        } else {
          const standalone =
            window.navigator.standalone === true ||
            matchMedia("(display-mode: standalone)").matches
          if (!standalone) {
            alert(
              "No iPhone o Safari nao permite tela cheia direto.\n\n" +
              "Toque em Compartilhar (o quadrado com a seta) e depois em " +
              "'Adicionar a Tela de Inicio'. Abrindo o app por esse icone, " +
              "ele roda em tela cheia, sem a barra do Safari."
            )
          }
        }
      })
    }
  }
}

const liveSocket = new LiveSocket("/live", Socket, {
  longPollFallbackMs: 2500,
  params: {
    _csrf_token: csrfToken,
    reviewer_id: localStorage.getItem("reviewer_id"),
    reviewer_name: localStorage.getItem("reviewer_name")
  },
  hooks: {...colocatedHooks, ...Hooks},
})

// Show progress bar on live navigation and form submits
topbar.config({barColors: {0: "#29d"}, shadowColor: "rgba(0, 0, 0, .3)"})
window.addEventListener("phx:page-loading-start", _info => topbar.show(300))
window.addEventListener("phx:page-loading-stop", _info => topbar.hide())

// connect if there are any LiveViews on the page
liveSocket.connect()

// expose liveSocket on window for web console debug logs and latency simulation:
// >> liveSocket.enableDebug()
// >> liveSocket.enableLatencySim(1000)  // enabled for duration of browser session
// >> liveSocket.disableLatencySim()
window.liveSocket = liveSocket

// The lines below enable quality of life phoenix_live_reload
// development features:
//
//     1. stream server logs to the browser console
//     2. click on elements to jump to their definitions in your code editor
//
if (process.env.NODE_ENV === "development") {
  window.addEventListener("phx:live_reload:attached", ({detail: reloader}) => {
    // Enable server log streaming to client.
    // Disable with reloader.disableServerLogs()
    reloader.enableServerLogs()

    // Open configured PLUG_EDITOR at file:line of the clicked element's HEEx component
    //
    //   * click with "c" key pressed to open at caller location
    //   * click with "d" key pressed to open at function component definition location
    let keyDown
    window.addEventListener("keydown", e => keyDown = e.key)
    window.addEventListener("keyup", _e => keyDown = null)
    window.addEventListener("click", e => {
      if(keyDown === "c"){
        e.preventDefault()
        e.stopImmediatePropagation()
        reloader.openEditorAtCaller(e.target)
      } else if(keyDown === "d"){
        e.preventDefault()
        e.stopImmediatePropagation()
        reloader.openEditorAtDef(e.target)
      }
    }, true)

    window.liveReloader = reloader
  })
}

