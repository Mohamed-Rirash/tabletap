// Web Push opt-in (build-plan.md Feature 20). Mounted on a wrapper div
// carrying the VAPID public key as a data attribute (same "render a
// key into the page as a data attribute" pattern root.html.heex
// already uses for the CSRF token) — `pushManager.subscribe()` needs
// it as the `applicationServerKey`.
//
// The actual push-permission prompt has to be triggered by a real
// user gesture (a click), never on mount — browsers silently ignore
// (or outright block) a `Notification.requestPermission()`/
// `pushManager.subscribe()` call that isn't inside a click handler.

function urlBase64ToUint8Array(base64String) {
  const padding = "=".repeat((4 - (base64String.length % 4)) % 4)
  const base64 = (base64String + padding).replace(/-/g, "+").replace(/_/g, "/")
  const raw = atob(base64)
  return Uint8Array.from([...raw].map((char) => char.charCodeAt(0)))
}

export default {
  mounted() {
    if (!("serviceWorker" in navigator) || !("PushManager" in window)) return

    navigator.serviceWorker.register("/sw.js")

    const button = this.el.querySelector("[data-action='subscribe']")
    if (button) button.addEventListener("click", () => this.subscribe())
  },

  async subscribe() {
    const registration = await navigator.serviceWorker.ready
    const vapidPublicKey = this.el.dataset.vapidPublicKey

    const subscription = await registration.pushManager.subscribe({
      userVisibleOnly: true,
      applicationServerKey: urlBase64ToUint8Array(vapidPublicKey),
    })

    // Flattened to match Tabletap.Notifications.PushSubscription's own
    // attrs shape server-side, rather than threading the browser's
    // nested {endpoint, keys: {p256dh, auth}} through unchanged.
    const json = subscription.toJSON()
    this.pushEvent("push_subscribe", {
      endpoint: json.endpoint,
      p256dh: json.keys.p256dh,
      auth: json.keys.auth,
      user_agent: navigator.userAgent,
    })
  },
}
