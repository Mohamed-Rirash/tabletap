import { useMemo } from "react";
import { createApiClient } from "@tabletap/shared";
import { useAuthStore } from "./store/authStore";

export { ApiError } from "@tabletap/shared";

// EXPO_PUBLIC_* vars are inlined into the client bundle by Expo's own
// convention — the dev fallback points at the local Phoenix dev server
// (config/dev.exs's default port). A real build sets EXPO_PUBLIC_API_URL
// to the deployed API origin.
export const API_BASE_URL = process.env.EXPO_PUBLIC_API_URL ?? "http://localhost:4000/api/v1";

/** Every staff-app screen is behind sign-in, unlike the customer app — this is always the client to use, never a bare guest client. */
export function useApi() {
  const accessToken = useAuthStore((s) => s.accessToken);
  const membershipId = useAuthStore((s) => s.currentMembershipId);

  return useMemo(
    () =>
      createApiClient({
        baseUrl: API_BASE_URL,
        accessToken: accessToken ?? undefined,
        membershipId: membershipId ?? undefined,
      }),
    [accessToken, membershipId],
  );
}
