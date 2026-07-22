import { useEffect, useState } from "react";
import { useRouter } from "expo-router";
import { FlatList, Pressable, StyleSheet, Text, View } from "react-native";
import { colors, radius, spacing, touchTarget, typography, type HistoryEntry } from "@tabletap/shared";
import { useApi } from "../src/api";
import { useAuthStore } from "../src/store/authStore";

/**
 * build-plan.md Feature 24 Commit 5 — "order history & spend", the
 * mobile equivalent of `UserLive.History`'s flat cross-venue order
 * list. Requires sign-in (Commit 5's own login + magic-link deep link)
 * — a customer who never signs in still gets full guest ordering via
 * Commits 3/4, matching the web's own guest-first design.
 */
export default function HistoryScreen() {
  const router = useRouter();
  const user = useAuthStore((s) => s.user);
  const api = useApi();
  const [orders, setOrders] = useState<HistoryEntry[] | null>(null);

  useEffect(() => {
    if (!user) return;
    api.getHistory().then((result) => setOrders(result.orders));
  }, [user, api]);

  if (!user) {
    return (
      <View style={styles.center}>
        <Text style={styles.body}>Sign in to see your order history and spend.</Text>
        <Pressable style={styles.button} onPress={() => router.push("/login")}>
          <Text style={styles.buttonText}>Sign in</Text>
        </Pressable>
      </View>
    );
  }

  if (!orders) {
    return (
      <View style={styles.center}>
        <Text style={styles.body}>Loading…</Text>
      </View>
    );
  }

  if (orders.length === 0) {
    return (
      <View style={styles.center}>
        <Text style={styles.body}>No orders yet.</Text>
      </View>
    );
  }

  return (
    <FlatList
      contentContainerStyle={styles.list}
      data={orders}
      keyExtractor={(order) => order.id}
      renderItem={({ item }) => (
        <Pressable
          style={styles.row}
          onPress={() =>
            router.push({ pathname: "/orders/[guestToken]", params: { guestToken: item.guest_token } })
          }
        >
          <View>
            <Text style={styles.venueName}>{item.venue_name}</Text>
            <Text style={styles.caption}>Order #{item.number}</Text>
          </View>
          <Text style={styles.total}>
            {item.total.currency} {item.total.amount}
          </Text>
        </Pressable>
      )}
    />
  );
}

const styles = StyleSheet.create({
  center: {
    flex: 1,
    alignItems: "center",
    justifyContent: "center",
    gap: spacing[3],
    backgroundColor: colors.light.background,
    padding: spacing[4],
  },
  body: {
    fontSize: typography.body.fontSize,
    color: colors.light.textSecondary,
    textAlign: "center",
  },
  button: {
    height: touchTarget.primary,
    paddingHorizontal: spacing[6],
    borderRadius: radius.full,
    backgroundColor: colors.brandDefault,
    alignItems: "center",
    justifyContent: "center",
  },
  buttonText: {
    color: "#fff",
    fontWeight: "700",
  },
  list: {
    padding: spacing[4],
    backgroundColor: colors.light.background,
  },
  row: {
    flexDirection: "row",
    justifyContent: "space-between",
    alignItems: "center",
    backgroundColor: colors.light.surface,
    borderWidth: 1,
    borderColor: colors.light.border,
    borderRadius: radius.lg,
    padding: spacing[4],
    marginBottom: spacing[3],
  },
  venueName: {
    fontSize: typography.itemName.fontSize,
    fontWeight: typography.itemName.fontWeight,
    color: colors.light.textPrimary,
  },
  caption: {
    fontSize: typography.caption.fontSize,
    color: colors.light.textMuted,
  },
  total: {
    fontSize: typography.price.fontSize,
    fontWeight: typography.price.fontWeight,
    color: colors.brandDefault,
  },
});
