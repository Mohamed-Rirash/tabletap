// Camera scan for serve-confirmation (ui-registry.md "QrScanner" —
// vendored `qr-scanner` lib, code-standards.md's approved JS dep list).
//
// Loaded via a *runtime* dynamic import of an absolute static URL
// (deliberately not a static relative import esbuild would bundle) —
// the library's own decode-worker fallback (used when the browser has
// no native BarcodeDetector, e.g. Safari) does `import("./qr-scanner-
// worker.min.js")` internally, which the browser resolves relative to
// wherever the importing module was *actually loaded from*. Bundling
// qr-scanner.min.js into app.js would make that resolve against the
// page's own URL instead (classic scripts have no stable module base),
// landing on a 404 that varies by route. Loading it as a real, separate
// module from a fixed `/vendor/...` URL keeps that resolution correct
// and stable everywhere. Both files live in `priv/static/vendor/`
// (tracked like fonts/images — vendor.static_paths in tabletap_web.ex).
const QR_SCANNER_MODULE_URL = "/vendor/qr-scanner.min.js"

export default {
  async mounted() {
    const {default: QrScannerLib} = await import(QR_SCANNER_MODULE_URL)

    this.scanner = new QrScannerLib(
      this.el,
      result => this.pushEvent("qr_scanned", {value: result.data}),
      {
        // Fires continuously while no code is in frame — expected noise,
        // not an error to surface.
        onDecodeError: () => {},
        highlightScanRegion: true,
        maxScansPerSecond: 5
      }
    )

    this.scanner.start().catch(error => {
      this.pushEvent("scan_error", {message: error?.message || String(error)})
    })
  },

  destroyed() {
    if (this.scanner) {
      this.scanner.stop()
      this.scanner.destroy()
      this.scanner = null
    }
  }
}
