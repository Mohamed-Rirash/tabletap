// iOS staff onboarding block (design-qa.md Q28) — iOS web push only
// works once installed to the home screen (16.4+), and even then is
// flaky, so a waiter running this in a plain Safari tab would miss
// every locked-phone alert. `navigator.standalone` is `true` only for
// an iOS home-screen-installed page (WebKit-specific, exposed
// regardless of which iOS browser chrome wraps it — Safari,
// Chrome-iOS, Firefox-iOS all share the same underlying WebKit engine
// per Apple's own requirement) — `undefined` everywhere else
// (Android, desktop), so this never fires off-iOS.
//
// Purely client-side: no server round trip, no LiveView assign — this
// is knowledge only the browser has, and the gate is just a full-screen
// overlay (same fixed-inset-0 modal shape as the existing scan_modal)
// revealed on mount when the condition holds.

export default {
  mounted() {
    const isIOS = /iPad|iPhone|iPod/.test(navigator.userAgent) && !window.MSStream
    const isStandalone = window.navigator.standalone === true

    if (isIOS && !isStandalone) this.el.classList.remove("hidden")
  },
}
