import { useEffect } from "react";
import { useRouter } from "expo-router";
import { ActivityIndicator, Pressable, StyleSheet, Text, View } from "react-native";
import { colors, radius, spacing, touchTarget, typography, type Membership } from "@tabletap/shared";
import { useAuthStore } from "../src/store/authStore";

/**
 * build-plan.md Feature 25 — role detection + mode switcher. Every
 * sign-in path (`login.tsx`'s password branch, `auth/[token].tsx`'s
 * magic-link callback) lands here after fetching `GET /api/v1/me/
 * memberships`. `authStore.setMemberships` already auto-selects a
 * lone membership, so this screen only ever shows a real picker when
 * there's an actual choice — one membership means an instant redirect
 * with nothing rendered.
 *
 * `:kitchen`/`:cashier`-only memberships have no mode in this app
 * (Kitchen Display / POS stay web-only, build-plan.md Features 14/15)
 * — surfaced honestly as "not available here" rather than a silent
 * dead end or a crash.
 */
function modeFor(role: Membership["role"]): "/waiter" | "/owner" | null {
  if (role === "waiter") return "/waiter";
  if (role === "owner" || role === "manager") return "/owner";
  return null;
}

export default function SelectRoleScreen() {
  const router = useRouter();
  const memberships = useAuthStore((s) => s.memberships);
  const currentMembershipId = useAuthStore((s) => s.currentMembershipId);
  const selectMembership = useAuthStore((s) => s.selectMembership);
  const clear = useAuthStore((s) => s.clear);

  function handleSignOut() {
    clear();
    router.replace("/login");
  }

  const current = memberships?.find((m) => m.membership_id === currentMembershipId) ?? null;
  const targetMode = current ? modeFor(current.role) : null;

  useEffect(() => {
    if (targetMode) router.replace(targetMode);
  }, [targetMode, router]);

  if (!memberships) {
    return (
      <View style={styles.center}>
        <ActivityIndicator />
      </View>
    );
  }

  if (memberships.length === 0) {
    return (
      <View style={styles.center}>
        <Text style={styles.body}>
          This account doesn&apos;t have staff access at any venue yet — ask a manager to invite
          you.
        </Text>
        <Pressable style={styles.signOutButton} onPress={handleSignOut}>
          <Text style={styles.signOutText}>Sign out</Text>
        </Pressable>
      </View>
    );
  }

  if (current && !targetMode) {
    return (
      <View style={styles.center}>
        <Text style={styles.body}>
          Your {current.role} role isn&apos;t available in this app yet — use the web dashboard
          instead.
        </Text>
        <Pressable style={styles.signOutButton} onPress={handleSignOut}>
          <Text style={styles.signOutText}>Sign out</Text>
        </Pressable>
      </View>
    );
  }

  if (targetMode) {
    return (
      <View style={styles.center}>
        <ActivityIndicator />
      </View>
    );
  }

  return (
    <View style={styles.container}>
      <Text style={styles.title}>Choose how you&apos;re working today</Text>
      {memberships.map((m) => (
        <Pressable
          key={m.membership_id}
          style={styles.roleCard}
          onPress={() => selectMembership(m.membership_id)}
        >
          <Text style={styles.roleName}>{m.venue_name ?? m.org_name}</Text>
          <Text style={styles.roleLabel}>{m.role}</Text>
        </Pressable>
      ))}
    </View>
  );
}

const styles = StyleSheet.create({
  container: {
    flex: 1,
    padding: spacing[4],
    gap: spacing[3],
    backgroundColor: colors.light.background,
  },
  center: {
    flex: 1,
    alignItems: "center",
    justifyContent: "center",
    gap: spacing[3],
    padding: spacing[4],
    backgroundColor: colors.light.background,
  },
  title: {
    fontSize: typography.sectionHeading.fontSize,
    fontWeight: typography.sectionHeading.fontWeight,
    color: colors.light.textPrimary,
    marginBottom: spacing[2],
  },
  roleCard: {
    borderWidth: 1,
    borderColor: colors.light.border,
    borderRadius: radius.md,
    padding: spacing[4],
    minHeight: touchTarget.primary,
    justifyContent: "center",
  },
  roleName: {
    fontSize: typography.itemName.fontSize,
    fontWeight: "600",
    color: colors.light.textPrimary,
  },
  roleLabel: {
    fontSize: typography.caption.fontSize,
    color: colors.light.textMuted,
    textTransform: "capitalize",
  },
  body: {
    fontSize: typography.body.fontSize,
    color: colors.light.textSecondary,
    textAlign: "center",
  },
  signOutButton: {
    marginTop: spacing[2],
    height: touchTarget.min,
    paddingHorizontal: spacing[4],
    borderRadius: radius.full,
    borderWidth: 1,
    borderColor: colors.light.border,
    alignItems: "center",
    justifyContent: "center",
  },
  signOutText: {
    color: colors.light.textPrimary,
    fontWeight: "600",
  },
});
