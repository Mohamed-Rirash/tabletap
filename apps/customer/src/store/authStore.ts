import { create } from "zustand";
import type { AuthTokens } from "@tabletap/shared";

/**
 * Session-only auth state (build-plan.md Feature 24 Commit 5) — same
 * deliberate, flagged limitation as `cartStore`: no persistence across
 * an app restart yet (no approved storage package for it).
 */
interface AuthState {
  accessToken: string | null;
  refreshToken: string | null;
  user: { id: string; email: string } | null;
  setTokens: (tokens: AuthTokens) => void;
  clear: () => void;
}

export const useAuthStore = create<AuthState>((set) => ({
  accessToken: null,
  refreshToken: null,
  user: null,
  setTokens: (tokens) =>
    set({
      accessToken: tokens.access_token,
      refreshToken: tokens.refresh_token,
      user: tokens.user,
    }),
  clear: () => set({ accessToken: null, refreshToken: null, user: null }),
}));
