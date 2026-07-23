import { useCallback, useEffect, useState } from "react";
import { useRouter } from "expo-router";
import { ActivityIndicator, Pressable, ScrollView, StyleSheet, Text, View } from "react-native";
import {
  colors,
  createSocket,
  joinVenueChannel,
  radius,
  spacing,
  typography,
  touchTarget,
  type OwnerDashboard,
  type VenueChannelHandle,
} from "@tabletap/shared";
import { API_BASE_URL, useApi } from "../../src/api";
import { useAuthStore } from "../../src/store/authStore";

/**
 * build-plan.md Feature 25 Commit 5 — owner mode: today's live
 * revenue/orders/operations/alerts, mirroring exactly the subset
 * `Manager.DashboardLive` itself renders (the deeper analytics-only
 * breakdowns stay web-only). Joins `venue:{id}:orders` and does a
 * *full reload* on any event — never a partial patch — matching
 * `Manager.DashboardLive`'s own moduledoc reasoning verbatim: cheap
 * enough to be simpler and more obviously correct than diffing.
 */
export default function OwnerHomeScreen() {
  const router = useRouter();
  const api = useApi();
  const accessToken = useAuthStore((s) => s.accessToken);
  const user = useAuthStore((s) => s.user);
  const clear = useAuthStore((s) => s.clear);

  const [dashboard, setDashboard] = useState<OwnerDashboard | null>(null);
  const [loading, setLoading] = useState(true);

  const load = useCallback(async () => {
    const data = await api.getOwnerDashboard();
    setDashboard(data);
  }, [api]);

  useEffect(() => {
    let cancelled = false;

    async function run() {
      setLoading(true);
      await load().finally(() => !cancelled && setLoading(false));
    }
    run();

    return () => {
      cancelled = true;
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  useEffect(() => {
    if (!dashboard) return;
    let handle: VenueChannelHandle | null = null;
    let cancelled = false;

    const socket = createSocket(API_BASE_URL.replace(/\/api\/v1\/?$/, ""), accessToken ?? undefined);
    socket.connect();
    joinVenueChannel(socket, dashboard.venue_id, () => {
      if (!cancelled) load();
    })
      .then((h) => {
        if (cancelled) h.leave();
        else handle = h;
      })
      .catch((reason) => console.warn("venue channel join failed", reason));

    return () => {
      cancelled = true;
      handle?.leave();
      socket.disconnect();
    };
    // Only re-join if the venue itself changes; `load` is stable enough for this effect's purpose.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [dashboard?.venue_id, accessToken]);

  function handleSignOut() {
    clear();
    router.replace("/login");
  }

  if (loading || !dashboard) {
    return (
      <View style={styles.center}>
        <ActivityIndicator />
      </View>
    );
  }

  const { summary, operations, alerts } = dashboard;
  const alertRows = [
    ["Low stock", alerts.low_stock.length],
    ["Delayed orders", alerts.delayed_orders.length],
    ["Unaccepted orders", alerts.unaccepted_orders.length],
    ["Flagged orders", alerts.flagged_orders.length],
    ["Sold out items", alerts.sold_out_items.length],
    ["Failed payments", alerts.failed_payments.length],
  ].filter(([, count]) => (count as number) > 0) as [string, number][];

  return (
    <ScrollView style={styles.container} contentContainerStyle={styles.content}>
      <View style={styles.header}>
        <View>
          <Text style={styles.title}>{dashboard.venue_name}</Text>
          <Text style={styles.caption}>{user?.email}</Text>
        </View>
        <Pressable onPress={handleSignOut}>
          <Text style={styles.signOutLink}>Sign out</Text>
        </Pressable>
      </View>

      <View style={styles.card}>
        <Text style={styles.sectionHeading}>Today</Text>
        <Text style={styles.bigNumber}>
          {summary.net_revenue.currency} {summary.net_revenue.amount}
        </Text>
        <Text style={styles.body}>
          {summary.order_count} orders
          {summary.avg_check
            ? ` · avg ${summary.avg_check.currency} ${summary.avg_check.amount}`
            : ""}
        </Text>
      </View>

      <View style={styles.card}>
        <Text style={styles.sectionHeading}>Right now</Text>
        <Text style={styles.body}>
          {operations.open_order_count} open order{operations.open_order_count === 1 ? "" : "s"}
          {operations.oldest_open_order_minutes != null
            ? ` · oldest ${operations.oldest_open_order_minutes}m`
            : ""}
        </Text>
        <Text style={styles.body}>~{operations.quoted_eta_minutes} min quoted ETA</Text>
        <Text style={styles.body}>
          On shift: {operations.on_shift.waiters} waiter
          {operations.on_shift.waiters === 1 ? "" : "s"}, {operations.on_shift.cashiers} cashier
          {operations.on_shift.cashiers === 1 ? "" : "s"}, {operations.on_shift.kitchen} kitchen
        </Text>
      </View>

      <View style={styles.card}>
        <Text style={styles.sectionHeading}>Alerts</Text>
        {alertRows.length === 0 && !alerts.subscription_issue ? (
          <Text style={styles.body}>Nothing needs your attention.</Text>
        ) : (
          <>
            {alertRows.map(([label, count]) => (
              <Text key={label} style={styles.alertRow}>
                {count} {label.toLowerCase()}
              </Text>
            ))}
            {alerts.subscription_issue && (
              <Text style={styles.alertRow}>
                Subscription {alerts.subscription_issue === "past_due" ? "payment past due" : "canceled"}
              </Text>
            )}
          </>
        )}
      </View>

      <Pressable style={styles.compareButton} onPress={() => router.push("/owner/venues")}>
        <Text style={styles.compareButtonText}>Compare venues</Text>
      </Pressable>
    </ScrollView>
  );
}

const styles = StyleSheet.create({
  container: {
    flex: 1,
    backgroundColor: colors.light.background,
  },
  content: {
    padding: spacing[4],
    gap: spacing[3],
  },
  center: {
    flex: 1,
    alignItems: "center",
    justifyContent: "center",
    backgroundColor: colors.light.background,
  },
  header: {
    flexDirection: "row",
    justifyContent: "space-between",
    alignItems: "flex-start",
  },
  title: {
    fontSize: typography.venueName.fontSize,
    fontWeight: typography.venueName.fontWeight,
    color: colors.light.textPrimary,
  },
  caption: {
    fontSize: typography.caption.fontSize,
    color: colors.light.textMuted,
  },
  signOutLink: {
    color: colors.brandDefault,
    fontSize: typography.caption.fontSize,
    fontWeight: "600",
  },
  card: {
    borderWidth: 1,
    borderColor: colors.light.border,
    borderRadius: radius.md,
    padding: spacing[4],
    gap: spacing[1],
  },
  sectionHeading: {
    fontSize: typography.sectionHeading.fontSize,
    fontWeight: typography.sectionHeading.fontWeight,
    color: colors.light.textPrimary,
    marginBottom: spacing[1],
  },
  bigNumber: {
    fontSize: 28,
    fontWeight: "800",
    color: colors.brandDefault,
  },
  body: {
    fontSize: typography.body.fontSize,
    color: colors.light.textSecondary,
  },
  alertRow: {
    fontSize: typography.body.fontSize,
    color: colors.danger,
  },
  compareButton: {
    height: touchTarget.primary,
    borderRadius: radius.full,
    borderWidth: 1,
    borderColor: colors.light.border,
    alignItems: "center",
    justifyContent: "center",
  },
  compareButtonText: {
    color: colors.light.textPrimary,
    fontWeight: "700",
  },
});
