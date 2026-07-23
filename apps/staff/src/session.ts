import { createApiClient, type AuthTokens } from "@tabletap/shared";
import { useRouter } from "expo-router";
import { API_BASE_URL } from "./api";
import { useAuthStore } from "./store/authStore";

/**
 * Shared by both sign-in paths (`app/login.tsx`'s password branch and
 * `app/auth/[token].tsx`'s magic-link callback, build-plan.md Feature
 * 25) — fetches the caller's memberships right after minting tokens
 * and always lands on `/select-role`, which itself decides whether
 * that's an instant redirect (one membership) or a real picker (more
 * than one). A fresh one-off client is built directly from `tokens.
 * access_token` rather than going through `useApi()`'s own memoized
 * hook — the store's `accessToken` wouldn't reflect `setTokens` until
 * the next render, and this fetch can't wait that long.
 */
export function useCompleteSignIn() {
  const router = useRouter();
  const setTokens = useAuthStore((s) => s.setTokens);
  const setMemberships = useAuthStore((s) => s.setMemberships);

  return async (tokens: AuthTokens) => {
    setTokens(tokens);

    const client = createApiClient({ baseUrl: API_BASE_URL, accessToken: tokens.access_token });
    const { memberships } = await client.getMemberships();
    setMemberships(memberships);

    router.replace("/select-role");
  };
}
