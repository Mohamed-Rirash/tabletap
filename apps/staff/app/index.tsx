import { useEffect } from "react";
import { useRouter } from "expo-router";
import { ActivityIndicator, StyleSheet, View } from "react-native";
import { colors } from "@tabletap/shared";
import { useAuthStore } from "../src/store/authStore";

/**
 * build-plan.md Feature 25 — the app's own entry route. Signed in
 * (real access token in the session-only store) goes straight to the
 * mode switcher, which itself handles the one-membership instant
 * redirect; signed out goes to login.
 */
export default function IndexScreen() {
  const router = useRouter();
  const accessToken = useAuthStore((s) => s.accessToken);

  useEffect(() => {
    router.replace(accessToken ? "/select-role" : "/login");
  }, [accessToken, router]);

  return (
    <View style={styles.center}>
      <ActivityIndicator />
    </View>
  );
}

const styles = StyleSheet.create({
  center: {
    flex: 1,
    alignItems: "center",
    justifyContent: "center",
    backgroundColor: colors.light.background,
  },
});
