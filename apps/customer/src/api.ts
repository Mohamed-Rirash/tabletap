import { createApiClient } from "@tabletap/shared";

export { ApiError } from "@tabletap/shared";

// EXPO_PUBLIC_* vars are inlined into the client bundle by Expo's own
// convention — the dev fallback points at the local Phoenix dev server
// (config/dev.exs's default port). A real build sets EXPO_PUBLIC_API_URL
// to the deployed API origin.
export const API_BASE_URL = process.env.EXPO_PUBLIC_API_URL ?? "http://localhost:4000/api/v1";

export const api = createApiClient({ baseUrl: API_BASE_URL });
