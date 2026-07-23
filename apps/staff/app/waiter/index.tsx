import { useCallback, useEffect, useRef, useState } from "react";
import { useRouter } from "expo-router";
import {
  ActivityIndicator,
  FlatList,
  Pressable,
  StyleSheet,
  Switch,
  Text,
  View,
} from "react-native";
import {
  colors,
  createSocket,
  joinWaiterChannel,
  radius,
  spacing,
  touchTarget,
  typography,
  type Order,
  type WaiterChannelHandle,
} from "@tabletap/shared";
import { API_BASE_URL, useApi, ApiError } from "../../src/api";
import { useAuthStore } from "../../src/store/authStore";

/**
 * build-plan.md Feature 25 Commit 4 — waiter mode: shift toggle, FIFO
 * queue, claim board, accept/claim, call-waiter alert. Scan-to-serve
 * is its own pushed screen (`app/waiter/serve/[orderId].tsx`) so the
 * camera gets the full screen, same shape as the customer app's own
 * scan screen. Mirrors `Waiter.QueueLive` exactly: boards always
 * rebuild from a REST fetch (`loadBoards`) — the joined channel is a
 * lightweight "something changed" refetch trigger, never the source
 * of truth (code-standards.md).
 */
export default function WaiterHomeScreen() {
  const router = useRouter();
  const api = useApi();
  const accessToken = useAuthStore((s) => s.accessToken);
  const membershipId = useAuthStore((s) => s.currentMembershipId);
  const user = useAuthStore((s) => s.user);
  const clear = useAuthStore((s) => s.clear);

  const [onShift, setOnShift] = useState<boolean | null>(null);
  const [queue, setQueue] = useState<Order[]>([]);
  const [claimBoard, setClaimBoard] = useState<Order[]>([]);
  const [loading, setLoading] = useState(true);
  const [toggling, setToggling] = useState(false);
  const [called, setCalled] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const calledTimer = useRef<ReturnType<typeof setTimeout> | null>(null);

  const loadBoards = useCallback(async () => {
    const [{ orders: q }, { orders: c }] = await Promise.all([
      api.getWaiterQueue(),
      api.getClaimBoard(),
    ]);
    setQueue(q);
    setClaimBoard(c);
  }, [api]);

  useEffect(() => {
    let cancelled = false;

    async function load() {
      setLoading(true);
      try {
        const { on_shift } = await api.getShiftStatus();
        if (cancelled) return;
        setOnShift(on_shift);
        await loadBoards();
      } finally {
        if (!cancelled) setLoading(false);
      }
    }
    load();

    return () => {
      cancelled = true;
    };
    // api/loadBoards are recreated per render but stable in effect — only re-run on membership switch.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [membershipId]);

  useEffect(() => {
    if (!membershipId) return;
    let handle: WaiterChannelHandle | null = null;
    let cancelled = false;

    const socket = createSocket(API_BASE_URL.replace(/\/api\/v1\/?$/, ""), accessToken ?? undefined);
    socket.connect();
    joinWaiterChannel(socket, membershipId, (event) => {
      if (cancelled) return;
      loadBoards();
      if (event === "waiter_called") {
        setCalled(true);
        if (calledTimer.current) clearTimeout(calledTimer.current);
        calledTimer.current = setTimeout(() => setCalled(false), 8000);
      }
    })
      .then((h) => {
        if (cancelled) h.leave();
        else handle = h;
      })
      .catch((reason) => console.warn("waiter channel join failed", reason));

    return () => {
      cancelled = true;
      handle?.leave();
      socket.disconnect();
    };
    // loadBoards is stable enough for this effect's purpose; only membershipId/accessToken matter.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [membershipId, accessToken]);

  async function handleToggleShift() {
    setToggling(true);
    setError(null);
    try {
      if (onShift) {
        await api.clockOut();
        setOnShift(false);
      } else {
        await api.clockIn();
        setOnShift(true);
      }
      await loadBoards();
    } catch (e) {
      setError(e instanceof ApiError ? e.message : "Couldn't update your shift.");
    } finally {
      setToggling(false);
    }
  }

  async function handleAccept(orderId: string) {
    try {
      await api.acceptOrder(orderId);
      await loadBoards();
    } catch (e) {
      setError(e instanceof ApiError ? e.message : "Couldn't accept that order.");
    }
  }

  async function handleClaim(orderId: string) {
    try {
      await api.claimOrder(orderId);
      await loadBoards();
    } catch (e) {
      setError(e instanceof ApiError ? e.message : "Someone else already claimed that order.");
    }
  }

  async function handleUnserveable(orderId: string) {
    try {
      await api.markUnserveable(orderId);
      await loadBoards();
    } catch (e) {
      setError(e instanceof ApiError ? e.message : "Couldn't flag that order.");
    }
  }

  function handleSignOut() {
    clear();
    router.replace("/login");
  }

  if (loading) {
    return (
      <View style={styles.center}>
        <ActivityIndicator />
      </View>
    );
  }

  return (
    <View style={styles.container}>
      <View style={styles.header}>
        <View>
          <Text style={styles.title}>Waiter mode</Text>
          <Text style={styles.caption}>{user?.email}</Text>
        </View>
        <Pressable onPress={handleSignOut}>
          <Text style={styles.signOutLink}>Sign out</Text>
        </Pressable>
      </View>

      <View style={styles.shiftRow}>
        <Text style={styles.shiftLabel}>{onShift ? "On shift" : "Off shift"}</Text>
        <Switch value={!!onShift} onValueChange={handleToggleShift} disabled={toggling} />
      </View>

      {called && (
        <View style={styles.calledBanner}>
          <Text style={styles.calledText}>A table is calling you!</Text>
        </View>
      )}

      {error && <Text style={styles.errorText}>{error}</Text>}

      <Text style={styles.sectionHeading}>Your queue</Text>
      <FlatList
        data={queue}
        keyExtractor={(o) => o.id}
        ListEmptyComponent={<Text style={styles.emptyText}>Nothing in your queue.</Text>}
        renderItem={({ item }) => (
          <OrderRow
            order={item}
            onAccept={item.status === "placed" ? () => handleAccept(item.id) : undefined}
            onServe={
              item.status === "ready"
                ? () => router.push({ pathname: "/waiter/serve/[orderId]", params: { orderId: item.id } })
                : undefined
            }
            onUnserveable={item.status === "ready" ? () => handleUnserveable(item.id) : undefined}
          />
        )}
      />

      <Text style={styles.sectionHeading}>Claim board</Text>
      <FlatList
        data={claimBoard}
        keyExtractor={(o) => o.id}
        ListEmptyComponent={<Text style={styles.emptyText}>No unclaimed orders.</Text>}
        renderItem={({ item }) => (
          <OrderRow order={item} onClaim={() => handleClaim(item.id)} />
        )}
      />
    </View>
  );
}

function OrderRow({
  order,
  onAccept,
  onClaim,
  onServe,
  onUnserveable,
}: {
  order: Order;
  onAccept?: () => void;
  onClaim?: () => void;
  onServe?: () => void;
  onUnserveable?: () => void;
}) {
  return (
    <View style={styles.orderRow}>
      <View style={styles.orderRowHeader}>
        <Text style={styles.orderNumber}>#{order.number}</Text>
        <View
          style={[styles.statusDot, { backgroundColor: colors.status[order.status as keyof typeof colors.status] ?? colors.light.border }]}
        />
        <Text style={styles.orderStatus}>{order.status}</Text>
      </View>
      {order.flag && <Text style={styles.flagText}>Flagged: {order.flag}</Text>}
      <View style={styles.orderActions}>
        {onAccept && (
          <Pressable style={styles.actionButton} onPress={onAccept}>
            <Text style={styles.actionButtonText}>Accept</Text>
          </Pressable>
        )}
        {onClaim && (
          <Pressable style={styles.actionButton} onPress={onClaim}>
            <Text style={styles.actionButtonText}>Claim</Text>
          </Pressable>
        )}
        {onServe && (
          <Pressable style={styles.actionButton} onPress={onServe}>
            <Text style={styles.actionButtonText}>Scan to serve</Text>
          </Pressable>
        )}
        {onUnserveable && (
          <Pressable style={styles.secondaryButton} onPress={onUnserveable}>
            <Text style={styles.secondaryButtonText}>Can&apos;t find customer</Text>
          </Pressable>
        )}
      </View>
    </View>
  );
}

const styles = StyleSheet.create({
  container: {
    flex: 1,
    padding: spacing[4],
    gap: spacing[2],
    backgroundColor: colors.light.background,
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
  shiftRow: {
    flexDirection: "row",
    justifyContent: "space-between",
    alignItems: "center",
    borderWidth: 1,
    borderColor: colors.light.border,
    borderRadius: radius.md,
    padding: spacing[3],
    marginVertical: spacing[2],
  },
  shiftLabel: {
    fontSize: typography.itemName.fontSize,
    fontWeight: "600",
    color: colors.light.textPrimary,
  },
  calledBanner: {
    backgroundColor: colors.info,
    borderRadius: radius.md,
    padding: spacing[3],
    alignItems: "center",
  },
  calledText: {
    color: "#fff",
    fontWeight: "700",
  },
  sectionHeading: {
    fontSize: typography.sectionHeading.fontSize,
    fontWeight: typography.sectionHeading.fontWeight,
    color: colors.light.textPrimary,
    marginTop: spacing[3],
  },
  emptyText: {
    fontSize: typography.body.fontSize,
    color: colors.light.textMuted,
    paddingVertical: spacing[2],
  },
  orderRow: {
    borderWidth: 1,
    borderColor: colors.light.border,
    borderRadius: radius.md,
    padding: spacing[3],
    marginVertical: spacing[1],
    gap: spacing[2],
  },
  orderRowHeader: {
    flexDirection: "row",
    alignItems: "center",
    gap: spacing[2],
  },
  orderNumber: {
    fontSize: typography.orderNumber.fontSize,
    fontWeight: typography.orderNumber.fontWeight,
    color: colors.light.textPrimary,
  },
  statusDot: {
    width: 10,
    height: 10,
    borderRadius: 5,
  },
  orderStatus: {
    fontSize: typography.caption.fontSize,
    color: colors.light.textSecondary,
    textTransform: "capitalize",
  },
  flagText: {
    fontSize: typography.caption.fontSize,
    color: colors.danger,
  },
  orderActions: {
    flexDirection: "row",
    flexWrap: "wrap",
    gap: spacing[2],
  },
  actionButton: {
    height: touchTarget.min,
    paddingHorizontal: spacing[4],
    borderRadius: radius.full,
    backgroundColor: colors.brandDefault,
    alignItems: "center",
    justifyContent: "center",
  },
  actionButtonText: {
    color: "#fff",
    fontWeight: "700",
  },
  secondaryButton: {
    height: touchTarget.min,
    paddingHorizontal: spacing[4],
    borderRadius: radius.full,
    borderWidth: 1,
    borderColor: colors.light.border,
    alignItems: "center",
    justifyContent: "center",
  },
  secondaryButtonText: {
    color: colors.light.textPrimary,
    fontWeight: "600",
  },
  errorText: {
    color: "#fff",
    backgroundColor: colors.danger,
    borderRadius: radius.md,
    padding: spacing[3],
    textAlign: "center",
  },
});
