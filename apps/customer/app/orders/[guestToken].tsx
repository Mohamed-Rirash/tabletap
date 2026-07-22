import { useEffect, useState } from "react";
import { useLocalSearchParams } from "expo-router";
import { ActivityIndicator, Pressable, StyleSheet, Text, View } from "react-native";
import {
  colors,
  spacing,
  statusSteps,
  typography,
  createSocket,
  joinOrderChannel,
  type Order,
  type OrderChannelHandle,
} from "@tabletap/shared";
import { api, API_BASE_URL } from "../../src/api";

/**
 * build-plan.md Feature 24 Commit 4 — mirrors `Public.OrderTrackerLive`'s
 * own states exactly: pending-cash, pending-wallet ("Confirming your
 * payment…"), terminal (cancelled/expired/refunded), served, and the
 * live 5-step timeline. Every screen must fully rebuild from a REST
 * fetch on reconnect (code-standards.md) — the channel join is a live
 * *optimization* layered on top of the initial `getOrder` fetch, never
 * the only source of truth.
 */
export default function TrackerScreen() {
  const { guestToken } = useLocalSearchParams<{ guestToken: string }>();
  const [order, setOrder] = useState<Order | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [callingWaiter, setCallingWaiter] = useState(false);

  useEffect(() => {
    let cancelled = false;
    let handle: OrderChannelHandle | null = null;

    api
      .getOrder(guestToken)
      .then(async (initial) => {
        if (cancelled) return;
        setOrder(initial);

        const socket = createSocket(apiOrigin(API_BASE_URL));
        socket.connect();
        handle = await joinOrderChannel(socket, initial.id, guestToken, (updated) => {
          if (!cancelled) setOrder(updated);
        }).catch((reason) => {
          // Never fatal — code-standards.md "channels are an
          // optimization, never the only source of truth" — the
          // screen already has the real REST-fetched order. Logged so
          // a genuine connectivity problem is at least visible.
          console.warn("order channel join failed", reason);
          return null;
        });
      })
      .catch(() => !cancelled && setError("Couldn't load this order — check your connection."));

    return () => {
      cancelled = true;
      handle?.leave();
    };
  }, [guestToken]);

  async function handleCallWaiter() {
    setCallingWaiter(true);
    try {
      await api.callWaiter(guestToken);
    } catch {
      // Best-effort — Q46's "the button shouldn't be showing right now"
      // cases (pickup venue, no table) surface as an ordinary failure
      // here, not a crash.
    } finally {
      setCallingWaiter(false);
    }
  }

  if (error) {
    return (
      <View style={styles.center}>
        <Text style={styles.body}>{error}</Text>
      </View>
    );
  }

  if (!order) {
    return (
      <View style={styles.center}>
        <ActivityIndicator />
      </View>
    );
  }

  return (
    <View style={styles.container}>
      <Text style={styles.orderNumber}>Order #{order.number}</Text>

      {order.status === "pending_payment" && order.payment?.provider === "cash" && (
        <StatusCard>
          <Text style={styles.bigNumber}>{order.number}</Text>
          <Text style={styles.body}>Show this number at the counter and pay cash there.</Text>
        </StatusCard>
      )}

      {order.status === "pending_payment" && order.payment?.provider !== "cash" && (
        <StatusCard>
          <Text style={styles.body}>Confirming your payment…</Text>
          <Text style={styles.caption}>This updates automatically — no need to refresh.</Text>
        </StatusCard>
      )}

      {["cancelled", "expired", "refunded"].includes(order.status) && (
        <StatusCard danger>
          <Text style={styles.body}>
            This order didn&apos;t go through — you have not been charged, or you&apos;ve been
            refunded.
          </Text>
        </StatusCard>
      )}

      {order.status === "served" && (
        <StatusCard success>
          <Text style={styles.body}>Order served — enjoy!</Text>
        </StatusCard>
      )}

      {order.status === "ready" && (
        <StatusCard>
          <Text style={styles.body}>Show staff your order code to collect it:</Text>
          <Text style={styles.bigNumber}>{order.guest_token.slice(0, 8).toUpperCase()}</Text>
        </StatusCard>
      )}

      {!["pending_payment", "cancelled", "expired", "refunded"].includes(order.status) && (
        <View style={styles.timeline}>
          {statusSteps.map((step) => {
            const stepIndex = statusSteps.indexOf(step);
            const currentIndex = statusSteps.indexOf(order.status as (typeof statusSteps)[number]);
            const done = stepIndex <= currentIndex;
            return (
              <View key={step} style={styles.timelineRow}>
                <View
                  style={[
                    styles.dot,
                    { backgroundColor: done ? colors.status[step] : colors.light.border },
                  ]}
                />
                <Text style={styles.timelineLabel}>{step}</Text>
                {step === order.status && order.eta_minutes != null && (
                  <Text style={styles.caption}>~{order.eta_minutes} min</Text>
                )}
              </View>
            );
          })}
        </View>
      )}

      {["placed", "accepted", "preparing", "ready"].includes(order.status) && (
        <Pressable style={styles.callButton} onPress={handleCallWaiter} disabled={callingWaiter}>
          <Text style={styles.callButtonText}>
            {callingWaiter ? "Calling…" : "Call waiter"}
          </Text>
        </Pressable>
      )}
    </View>
  );
}

function StatusCard({
  children,
  danger,
  success,
}: {
  children: React.ReactNode;
  danger?: boolean;
  success?: boolean;
}) {
  return (
    <View
      style={[
        styles.statusCard,
        danger && { borderColor: colors.danger },
        success && { borderColor: colors.success },
      ]}
    >
      {children}
    </View>
  );
}

/** The API base URL is `<origin>/api/v1` — the socket lives at `<origin>/socket`. */
function apiOrigin(apiBaseUrl: string): string {
  return apiBaseUrl.replace(/\/api\/v1\/?$/, "");
}

const styles = StyleSheet.create({
  container: {
    flex: 1,
    padding: spacing[4],
    backgroundColor: colors.light.background,
  },
  center: {
    flex: 1,
    alignItems: "center",
    justifyContent: "center",
    backgroundColor: colors.light.background,
  },
  orderNumber: {
    fontSize: typography.orderNumber.fontSize,
    fontWeight: typography.orderNumber.fontWeight,
    color: colors.light.textPrimary,
    marginBottom: spacing[4],
  },
  statusCard: {
    borderWidth: 1,
    borderColor: colors.light.border,
    borderRadius: 16,
    padding: spacing[4],
    alignItems: "center",
    gap: spacing[2],
    marginBottom: spacing[4],
  },
  body: {
    fontSize: typography.body.fontSize,
    color: colors.light.textSecondary,
    textAlign: "center",
  },
  caption: {
    fontSize: typography.caption.fontSize,
    color: colors.light.textMuted,
  },
  bigNumber: {
    fontSize: 32,
    fontWeight: "800",
    color: colors.brandDefault,
  },
  timeline: {
    gap: spacing[3],
  },
  timelineRow: {
    flexDirection: "row",
    alignItems: "center",
    gap: spacing[3],
  },
  dot: {
    width: 12,
    height: 12,
    borderRadius: 6,
  },
  timelineLabel: {
    fontSize: typography.body.fontSize,
    color: colors.light.textPrimary,
    textTransform: "capitalize",
    flex: 1,
  },
  callButton: {
    marginTop: spacing[6],
    height: 56,
    borderRadius: 9999,
    backgroundColor: colors.info,
    alignItems: "center",
    justifyContent: "center",
  },
  callButtonText: {
    color: "#fff",
    fontWeight: "700",
  },
});
