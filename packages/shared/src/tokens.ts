/**
 * Design tokens ported 1:1 from context/ui-tokens.md — the single
 * source of truth for both the web app (CSS variables) and these
 * mobile apps (plain TS constants, since React Native has no CSS
 * variables). Keep this file in sync with ui-tokens.md by hand; do not
 * invent new values here.
 */

export const colors = {
  light: {
    background: "#FAF8F5",
    surface: "#FFFFFF",
    surfaceSunken: "#F1EDE7",
    border: "#E5DFD6",
    textPrimary: "#241E19",
    textSecondary: "#6E655C",
    textMuted: "#9C948A",
  },
  dark: {
    background: "#17151A",
    surface: "#211E24",
    surfaceRaised: "#2B2730",
    border: "#3A3540",
    textPrimary: "#F4F1EC",
    textSecondary: "#A9A19B",
  },
  accent: "#C96F2E",
  accentDark: "#A6551C",
  accentMuted: "rgba(201, 111, 46, 0.12)",
  // Tenant brand overrides this per venue on the customer surface only —
  // this is just the fallback when a venue hasn't set one.
  brandDefault: "#C96F2E",
  status: {
    placed: "#8A63D2",
    accepted: "#2E7DC9",
    preparing: "#D9822B",
    ready: "#2FA45C",
    served: "#57906B",
    cancelled: "#C0392B",
  },
  success: "#2FA45C",
  warning: "#D9A62B",
  danger: "#C0392B",
  info: "#2E7DC9",
} as const;

export const radius = {
  sm: 8,
  md: 12,
  lg: 16,
  full: 9999,
} as const;

export const spacing = {
  1: 4,
  2: 8,
  3: 12,
  4: 16,
  6: 24,
  8: 32,
} as const;

/** Minimum touch target — 56 for primary actions per ui-tokens.md. */
export const touchTarget = {
  min: 44,
  primary: 56,
} as const;

export const typography = {
  venueName: { fontSize: 20, fontWeight: "700" as const },
  sectionHeading: { fontSize: 17, fontWeight: "600" as const },
  itemName: { fontSize: 16, fontWeight: "600" as const },
  body: { fontSize: 14, fontWeight: "400" as const },
  price: { fontSize: 15, fontWeight: "700" as const },
  caption: { fontSize: 12, fontWeight: "500" as const },
  orderNumber: { fontSize: 15, fontWeight: "800" as const },
} as const;

/** Order-status timeline order, platform-fixed — never reorder or retheme per tenant. */
export const statusSteps = [
  "placed",
  "accepted",
  "preparing",
  "ready",
  "served",
] as const;
