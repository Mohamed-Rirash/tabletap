import { useRouter } from "expo-router";
import { Pressable, StyleSheet, Text, View } from "react-native";
import { colors, radius, spacing, touchTarget, typography } from "@tabletap/shared";
import { useAuthStore } from "../../src/store/authStore";

/**
 * build-plan.md Feature 25 Commit 3 — placeholder waiter-mode landing
 * screen, proving the full sign-in → mode-switcher → waiter-mode
 * navigation genuinely works end to end. Commit 4 replaces this with
 * the real shift toggle / FIFO queue / claim board / scan-to-serve
 * screen; nothing here is a stand-in for real data.
 */
export default function WaiterHomeScreen() {
  const router = useRouter();
  const user = useAuthStore((s) => s.user);
  const clear = useAuthStore((s) => s.clear);

  function handleSignOut() {
    clear();
    router.replace("/login");
  }

  return (
    <View style={styles.container}>
      <Text style={styles.title}>Waiter mode</Text>
      <Text style={styles.body}>Signed in as {user?.email}</Text>
      <Pressable style={styles.button} onPress={handleSignOut}>
        <Text style={styles.buttonText}>Sign out</Text>
      </Pressable>
    </View>
  );
}

const styles = StyleSheet.create({
  container: {
    flex: 1,
    padding: spacing[4],
    justifyContent: "center",
    gap: spacing[3],
    backgroundColor: colors.light.background,
  },
  title: {
    fontSize: typography.venueName.fontSize,
    fontWeight: typography.venueName.fontWeight,
    color: colors.light.textPrimary,
  },
  body: {
    fontSize: typography.body.fontSize,
    color: colors.light.textSecondary,
  },
  button: {
    marginTop: spacing[3],
    height: touchTarget.min,
    borderRadius: radius.full,
    borderWidth: 1,
    borderColor: colors.light.border,
    alignItems: "center",
    justifyContent: "center",
  },
  buttonText: {
    color: colors.light.textPrimary,
    fontWeight: "600",
  },
});
