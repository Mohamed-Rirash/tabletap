import { useEffect, useState } from "react";
import { useLocalSearchParams } from "expo-router";
import { ActivityIndicator, StyleSheet, Text, View } from "react-native";
import { colors, spacing, typography } from "@tabletap/shared";
import { useApi, ApiError } from "../../src/api";
import { useCompleteSignIn } from "../../src/session";

/**
 * build-plan.md Feature 25 — lands here from the `tabletap-staff://
 * auth/:token` deep link `login.tsx`'s magic-link request mints
 * (`app.json`'s own `scheme: "tabletap-staff"`, separate from the
 * customer app's `tabletap` scheme so both apps can be installed on
 * the same device without fighting over one custom URL scheme).
 */
export default function AuthCallbackScreen() {
  const { token } = useLocalSearchParams<{ token: string }>();
  const api = useApi();
  const completeSignIn = useCompleteSignIn();
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    let cancelled = false;
    api
      .confirmMagicLink(token)
      .then((tokens) => {
        if (cancelled) return;
        return completeSignIn(tokens);
      })
      .catch((e) => {
        if (cancelled) return;
        setError(e instanceof ApiError ? e.message : "That login link is invalid or expired.");
      });
    return () => {
      cancelled = true;
    };
    // api/completeSignIn are stable across renders — only `token` should re-trigger the exchange.
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
