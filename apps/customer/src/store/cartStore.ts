import { create } from "zustand";
import type { Cart } from "@tabletap/shared";

/**
 * Session-only cart/table state (build-plan.md Feature 24 Commit 3) —
 * the RN equivalent of the web's `guest_token` cookie, in-memory for
 * now. Known, deliberate scope limit: no persistence across an app
 * restart yet (`@react-native-async-storage/async-storage` isn't on
 * code-standards.md's approved package list — adding it needs that
 * list updated first, not a silent addition).
 */
interface CartState {
  venueSlug: string | null;
  tableId: string | null;
  guestToken: string | null;
  cart: Cart | null;
  setTable: (venueSlug: string, tableId: string | null) => void;
  setGuestToken: (token: string) => void;
  setCart: (cart: Cart) => void;
  clear: () => void;
}

export const useCartStore = create<CartState>((set) => ({
  venueSlug: null,
  tableId: null,
  guestToken: null,
  cart: null,
  setTable: (venueSlug, tableId) => set({ venueSlug, tableId }),
  setGuestToken: (guestToken) => set({ guestToken }),
  setCart: (cart) => set({ cart, guestToken: cart.guest_token }),
  clear: () => set({ venueSlug: null, tableId: null, guestToken: null, cart: null }),
}));
