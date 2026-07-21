// Loud in-app audio alert on order assignment (design-qa.md Q28 — the
// accepted mitigation for iOS's unreliable web push until the Phase 8
// native staff app: "loud in-app audio alert on assignment while the
// app is open"). A synthesized oscillator beep, not a bundled sound
// file — no binary asset to source, license, or commit.
//
// Browsers only allow audio to start from a real user gesture, and
// `play_alert` arrives over the WebSocket, not a click — so the
// AudioContext is created/resumed on the page's *first* click,
// wherever it happens (Start shift, accepting an order, anything),
// which is enough to unlock it for the rest of the session per every
// major browser's autoplay policy.

export default {
  mounted() {
    this.ctx = null
    this.unlock = () => this.ensureContext()
    document.addEventListener("click", this.unlock, { once: true })

    this.handleEvent("play_alert", () => this.beep())
  },

  destroyed() {
    document.removeEventListener("click", this.unlock)
  },

  ensureContext() {
    if (!this.ctx) this.ctx = new (window.AudioContext || window.webkitAudioContext)()
    if (this.ctx.state === "suspended") this.ctx.resume()
  },

  beep() {
    this.ensureContext()
    if (!this.ctx || this.ctx.state === "suspended") return

    const oscillator = this.ctx.createOscillator()
    const gain = this.ctx.createGain()

    oscillator.type = "sine"
    oscillator.frequency.value = 880 // A5 — attention-grabbing, not painful
    gain.gain.setValueAtTime(0.001, this.ctx.currentTime)
    gain.gain.exponentialRampToValueAtTime(0.3, this.ctx.currentTime + 0.02)
    gain.gain.exponentialRampToValueAtTime(0.001, this.ctx.currentTime + 0.6)

    oscillator.connect(gain)
    gain.connect(this.ctx.destination)

    oscillator.start()
    oscillator.stop(this.ctx.currentTime + 0.6)
  },
}
