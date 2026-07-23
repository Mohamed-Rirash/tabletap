import { useEffect, useState } from "react";
import { useRouter } from "expo-router";
import { ActivityIndicator, Pressable, ScrollView, StyleSheet, Text, View } from "react-native";
import {
  colors,
  radius,
  spacing,
  touchTarget,
  typography,
  type VenueComparisonRow,
  type VenueTotals,
} from "@tabletap/shared";
import { useApi, ApiError } from "../../src/api";

type Range = "today" | "7d" | "30d";

/**
 * build-plan.md Feature 25 Commit 5 — cross-venue comparison, the
 * mobile mirror of `Manager.Analytics.VenueComparisonLive`. Pro-tier
 * and owner only, gated server-side (`OwnerController.venues/2`) — a
 * `plan_upgrade_required` response gets the same graceful "upgrade to
 * see this" framing the web's own paywall redirect gives, not an error
 * screen.
 */
export default function VenueComparisonScreen() {
  const router = useRouter();
  const api = useApi();
  const [range, setRange] = useState<Range>("7d");
  const [rows, setRows] = useState<VenueComparisonRow[] | null>(null);
  const [totals, setTotals] = useState<VenueTotals | null>(null);
  const [loading, setLoading] = useState(true);
  const [upgradeRequired, setUpgradeRequired] = useState(false);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    let cancelled = false;

    async function run() {
      setLoading(true);
      setError(null);
      setUpgradeRequired(false);

      try {
        const { venues, totals } = await api.getVenueComparison(range);
        if (cancelled) return;
        setRows(venues);
        setTotals(totals);
      } catch (e) {
        if (cancelled) return;
        if (e instanceof ApiError && e.message === "plan_upgrade_required") {
          setUpgradeRequired(true);
        } else {
          setError("Couldn't load venue comparison.");
        }
      } finally {
        if (!cancelled) setLoading(false);
      }
    }
    run();

    return () => {
      cancelled = true;
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [range]);

  if (loading) {
    return (
      <View style={styles.center}>
        <ActivityIndicator />
      </View>
    );
  }

  if (upgradeRequired) {
    return (
      <View style={styles.center}>
        <Text style={styles.body}>
          Comparing venues side by side is a Pro plan feature. Upgrade to unlock it.
        </Text>
        <Pressable style={styles.backButton} onPress={() => router.back()}>
          <Text style={styles.backButtonText}>Back</Text>
        </Pressable>
      </View>
    );
  }

  if (error) {
    return (
      <View style={styles.center}>
        <Text style={styles.body}>{error}</Text>
      </View>
    );
  }

  return (
    <ScrollView style={styles.container} contentContainerStyle={styles.content}>
      <Text style={styles.title}>Venue comparison</Text>

      <View style={styles.rangeRow}>
        {(["today", "7d", "30d"] as Range[]).map((r) => (
          <Pressable
            key={r}
            style={[styles.rangeButton, range === r && styles.rangeButtonActive]}
            onPress={() => setRange(r)}
          >
            <Text style={[styles.rangeButtonText, range === r && styles.rangeButtonTextActive]}>
              {r}
            </Text>
          </Pressable>
        ))}
      </View>

      {totals && (
        <Text style={styles.caption}>
          {totals.venue_count} venue{totals.venue_count === 1 ? "" : "s"} · {totals.order_count}{" "}
          orders total
        </Text>
      )}

      {rows?.map((row) => (
        <View key={row.venue_id} style={styles.card}>
          <Text style={styles.venueName}>{row.venue_name}</Text>
          <Text style={styles.body}>
            {row.net_revenue.currency} {row.net_revenue.amount} · {row.order_count} orders
          </Text>
          {row.avg_check && (
            <Text style={styles.caption}>
              avg {row.avg_check.currency} {row.avg_check.amount}
            </Text>
          )}
          {row.avg_rating != null && (
            <Text style={styles.caption}>★ {row.avg_rating.toFixed(1)}</Text>
          )}
        </View>
      ))}
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
    gap: spacing[3],
    padding: spacing[4],
    backgroundColor: colors.light.background,
  },
  title: {
    fontSize: typography.venueName.fontSize,
    fontWeight: typography.venueName.fontWeight,
    color: colors.light.textPrimary,
  },
  rangeRow: {
    flexDirection: "row",
    gap: spacing[2],
  },
  rangeButton: {
    height: touchTarget.min,
    paddingHorizontal: spacing[4],
    borderRadius: radius.full,
    borderWidth: 1,
    borderColor: colors.light.border,
    alignItems: "center",
    justifyContent: "center",
  },
  rangeButtonActive: {
    backgroundColor: colors.brandDefault,
    borderColor: colors.brandDefault,
  },
  rangeButtonText: {
    color: colors.light.textPrimary,
    fontWeight: "600",
  },
  rangeButtonTextActive: {
    color: "#fff",
  },
  caption: {
    fontSize: typography.caption.fontSize,
    color: colors.light.textMuted,
  },
  card: {
    borderWidth: 1,
    borderColor: colors.light.border,
    borderRadius: radius.md,
    padding: spacing[4],
    gap: spacing[1],
  },
  venueName: {
    fontSize: typography.itemName.fontSize,
    fontWeight: "700",
    color: colors.light.textPrimary,
  },
  body: {
    fontSize: typography.body.fontSize,
    color: colors.light.textSecondary,
  },
  backButton: {
    height: touchTarget.min,
    paddingHorizontal: spacing[6],
    borderRadius: radius.full,
    borderWidth: 1,
    borderColor: colors.light.border,
    alignItems: "center",
    justifyContent: "center",
  },
  backButtonText: {
    color: colors.light.textPrimary,
    fontWeight: "600",
  },
});
