import { useEffect, useState } from "react";
import { useLocalSearchParams, useRouter } from "expo-router";
import { ActivityIndicator, StyleSheet, Text, View } from "react-native";
import { colors, spacing, typography } from "@tabletap/shared";
import { api, ApiError } from "../../src/api";
import { useAuthStore } from "../../src/store/authStore";

/**
 * build-plan.md Feature 24 Commit 5 — lands here from the
 * `tabletap://auth/:token` deep link Feature 23 Commit 1's magic-link
 * email mints (`expo-router`'s `scheme: "tabletap"` config already
 * routes it here, since a route file's path *is* the deep-link path).
 * Exchanges the token for a real access/refresh pair exactly like
 * `POST /api/v1/auth/confirm`'s own contract, then lands on history.
 */
export default function AuthCallbackScreen() {
  const { token } = useLocalSearchParams<{ token: string }>();
  const router = useRouter();
  const setTokens = useAuthStore((s) => s.setTokens);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    let cancelled = false;
    api
      .confirmMagicLink(token)
      .then((tokens) => {
        if (cancelled) return;
        setTokens(tokens);
        router.replace("/history");
      })
      .catch((e) => {
        if (cancelled) return;
        setError(e instanceof ApiError ? e.message : "That login link is invalid or expired.");
      });
    return () => {
      cancelled = true;
    };
    // router/setTokens are stable across renders — only `token` should re-trigger the exchange.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [token]);

  return (
    <View style={styles.container}>
      {error ? (
        <Text style={styles.body}>{error}</Text>
      ) : (
        <>
          <ActivityIndicator />
          <Text style={styles.body}>Signing you in…</Text>
        </>
      )}
    </View>
  );
}

const styles = StyleSheet.create({
  container: {
    flex: 1,
    alignItems: "center",
    justifyContent: "center",
    gap: spacing[3],
    backgroundColor: colors.light.background,
  },
  body: {
    fontSize: typography.body.fontSize,
    color: colors.light.textSecondary,
  },
});
