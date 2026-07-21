// Web Push service worker (build-plan.md Feature 20). Deliberately a
// real static file at the origin root, not bundled by esbuild — same
// "loaded from a fixed URL, not the app bundle" reasoning as
// assets/js/hooks/qr_scanner.js's vendored lib, except here it's not
// optional: a service worker's default scope is its own path and
// below, so serving this from anywhere but the root would only ever
// cover a subtree of the app.
//
// Push payloads are always `{title, body, url}` — see
// Tabletap.Notifications' own moduledoc for the payload shape every
// caller sends.

self.addEventListener("push", (event) => {
  if (!event.data) return

  const payload = event.data.json()

  event.waitUntil(
    self.registration.showNotification(payload.title, {
      body: payload.body,
      data: { url: payload.url || "/" },
      // Loud/attention-grabbing on the two roles this feature targets
      // (waiter new-order/call, manager low-stock) — a missed order is
      // the exact failure mode design-qa.md Q28 accepts the risk on
      // until the native staff app.
      requireInteraction: true,
    })
  )
})

self.addEventListener("notificationclick", (event) => {
  event.notification.close()
  const targetUrl = event.notification.data && event.notification.data.url

  event.waitUntil(
    self.clients.matchAll({ type: "window", includeUncontrolled: true }).then((clients) => {
      for (const client of clients) {
        if (client.url.endsWith(targetUrl) && "focus" in client) return client.focus()
      }

      if (self.clients.openWindow) return self.clients.openWindow(targetUrl)
    })
  )
})
