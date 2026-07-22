import { useMemo } from "react";
import { createApiClient } from "@tabletap/shared";
import { useAuthStore } from "./store/authStore";

export { ApiError } from "@tabletap/shared";

// EXPO_PUBLIC_* vars are inlined into the client bundle by Expo's own
// convention — the dev fallback points at the local Phoenix dev server
// (config/dev.exs's default port). A real build sets EXPO_PUBLIC_API_URL
// to the deployed API origin.
export const API_BASE_URL = process.env.EXPO_PUBLIC_API_URL ?? "http://localhost:4000/api/v1";

/** The guest-token-only client — every customer flow before Commit 5's login screen used this directly. */
export const api = createApiClient({ baseUrl: API_BASE_URL });

/** A client bound to the current signed-in user's access token, if any — for `/me/history` and other bearer-protected calls. Recomputed whenever the token changes. */
export function useApi() {
  const accessToken = useAuthStore((s) => s.accessToken);
  return useMemo(
    () => createApiClient({ baseUrl: API_BASE_URL, accessToken: accessToken ?? undefined }),
    [accessToken],
  );
}
