import { create } from "zustand";
import type { AuthTokens, Membership } from "@tabletap/shared";

/**
 * Session-only auth + role state (build-plan.md Feature 25) — same
 * deliberate, flagged no-persistence limitation `apps/customer`'s
 * `authStore` already documents: no approved storage package for
 * surviving an app restart yet.
 *
 * `memberships`/`currentMembershipId` are new relative to the customer
 * app: a staff member can hold more than one membership (a `:waiter`
 * at one venue, an `:owner` at another, or both roles at the same
 * org), and every `/waiter`/`/owner` request needs to know which one
 * is "current" (`ApiClientConfig.membershipId`, fed to `ApiAuth.
 * assign_scope/2` exactly like the web's own venue switcher).
 */
interface AuthState {
  accessToken: string | null;
  refreshToken: string | null;
  user: { id: string; email: string } | null;
  memberships: Membership[] | null;
  currentMembershipId: string | null;
  setTokens: (tokens: AuthTokens) => void;
  setMemberships: (memberships: Membership[]) => void;
  selectMembership: (membershipId: string) => void;
  clear: () => void;
}

export const useAuthStore = create<AuthState>((set) => ({
  accessToken: null,
  refreshToken: null,
  user: null,
  memberships: null,
  currentMembershipId: null,
  setTokens: (tokens) =>
    set({
      accessToken: tokens.access_token,
      refreshToken: tokens.refresh_token,
      user: tokens.user,
    }),
  setMemberships: (memberships) =>
    set({
      memberships,
      // A single membership needs no explicit switcher tap — select it
      // immediately so the mode-switcher screen only ever shows when
      // there's a real choice to make.
      currentMembershipId: memberships.length === 1 ? memberships[0].membership_id : null,
    }),
  selectMembership: (membershipId) => set({ currentMembershipId: membershipId }),
  clear: () =>
    set({
      accessToken: null,
      refreshToken: null,
      user: null,
      memberships: null,
      currentMembershipId: null,
    }),
}));
