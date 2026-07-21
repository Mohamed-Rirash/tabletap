// Offline/reconnect banner + "Install app" prompt (build-plan.md Feature
// 20). Both elements live in root.html.heex's own static shell, outside
// any LiveView's managed DOM subtree — that's why this is plain JS wired
// once at page load instead of a phx-hook: a hook only initializes for
// elements inside a View's socket-managed container.

export function initOfflineBanner(liveSocket) {
  const banner = document.getElementById("offline-banner")
  if (!banner) return

  const show = () => banner.classList.remove("hidden")
  const hide = () => banner.classList.add("hidden")

  window.addEventListener("offline", show)
  window.addEventListener("online", hide)
  liveSocket.socket.onError(show)
  liveSocket.socket.onOpen(hide)
}

export function initInstallPrompt() {
  const button = document.getElementById("pwa-install-button")
  if (!button) return

  let deferredPrompt = null

  window.addEventListener("beforeinstallprompt", (event) => {
    event.preventDefault()
    deferredPrompt = event
    button.classList.remove("hidden")
  })

  button.addEventListener("click", async () => {
    if (!deferredPrompt) return
    button.classList.add("hidden")
    deferredPrompt.prompt()
    deferredPrompt = null
  })

  window.addEventListener("appinstalled", () => button.classList.add("hidden"))
}
