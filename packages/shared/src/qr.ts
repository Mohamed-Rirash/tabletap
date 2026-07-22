/**
 * A table's printed QR encodes the full web URL (`Manager.TablesLive`'s
 * print sheet: `url(~p"/t/#{table.qr_token}")`), not a bare token — the
 * app has to pull the token back out of whatever the camera scanned.
 * Pure string parsing, no network/business logic (code-standards.md
 * "zero business logic in the apps" — this is just URL shape, not a
 * server decision).
 */
export function extractQrToken(scannedValue: string): string | null {
  const match = scannedValue.match(/\/t\/([^/?#]+)/);
  if (match) return match[1];

  // A bare token (no /t/ prefix at all) — tolerate it for a manually
  // typed/QA value, but reject anything that still looks like some
  // other URL/path we don't recognize.
  if (/^[A-Za-z0-9_-]+$/.test(scannedValue)) return scannedValue;

  return null;
}
