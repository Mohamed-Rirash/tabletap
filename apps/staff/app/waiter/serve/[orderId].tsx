import { useState } from "react";
import { CameraView, useCameraPermissions, type BarcodeScanningResult } from "expo-camera";
import { useLocalSearchParams, useRouter } from "expo-router";
import { ActivityIndicator, Pressable, StyleSheet, Text, View } from "react-native";
import { colors, spacing, touchTarget, typography, extractQrToken } from "@tabletap/shared";
import { useApi, ApiError } from "../../../src/api";

/**
 * build-plan.md Feature 25 Commit 4 — scan-to-serve, the waiter-side
 * mirror of `Waiter.QueueLive`'s in-app QR scanner: the scanned value
 * must match the order's own serve token (the table's printed
 * `qr_token`, or the customer's tracker-page `guest_token` for a
 * table-less order — `Ordering.confirm_served_by_scan/3`'s own
 * comparison, unchanged here). A table QR encodes the full `/t/:token`
 * web URL (same as the customer app's own scan screen), so this reuses
 * `extractQrToken` to pull the bare token back out either way.
 */
export default function ServeScreen() {
  const { orderId } = useLocalSearchParams<{ orderId: string }>();
  const router = useRouter();
  const api = useApi();
  const [permission, requestPermission] = useCameraPermissions();
  const [scannedOnce, setScannedOnce] = useState(false);
  const [submitting, setSubmitting] = useState(false);
  const [error, setError] = useState<string | null>(null);

  async function handleScan(result: BarcodeScanningResult) {
    if (scannedOnce || submitting) return;
    setScannedOnce(true);
    setError(null);
    setSubmitting(true);

    const value = extractQrToken(result.data) ?? result.data;

    try {
      await api.serveOrder(orderId, value);
      router.back();
    } catch (e) {
      setError(
        e instanceof ApiError && e.message === "token_mismatch"
          ? "That code doesn't match this order — try again."
          : "Couldn't mark this order served.",
      );
      setScannedOnce(false);
    } finally {
      setSubmitting(false);
    }
  }

  if (!permission) {
    return <View style={styles.container} />;
  }

  if (!permission.granted) {
    return (
      <View style={styles.container}>
        <Text style={styles.body}>We need camera access to scan the customer&apos;s code.</Text>
        <Pressable style={styles.button} onPress={requestPermission}>
          <Text style={styles.buttonText}>Enable camera</Text>
        </Pressable>
      </View>
    );
  }

  return (
    <View style={styles.container}>
      <CameraView
        style={StyleSheet.absoluteFill}
        barcodeScannerSettings={{ barcodeTypes: ["qr"] }}
        onBarcodeScanned={handleScan}
      />
      <View style={styles.overlay}>
        <Text style={styles.overlayTitle}>Scan the table or customer&apos;s code</Text>
        {submitting && <ActivityIndicator color="#fff" style={{ marginTop: spacing[3] }} />}
        {error && <Text style={styles.errorText}>{error}</Text>}
        <Pressable style={styles.cancelButton} onPress={() => router.back()}>
          <Text style={styles.cancelButtonText}>Cancel</Text>
        </Pressable>
      </View>
    </View>
  );
}

const styles = StyleSheet.create({
  container: {
    flex: 1,
    alignItems: "center",
    justifyContent: "center",
    gap: spacing[2],
    backgroundColor: colors.light.background,
  },
  body: {
    fontSize: typography.body.fontSize,
    color: colors.light.textSecondary,
    textAlign: "center",
    paddingHorizontal: spacing[6],
  },
  button: {
    marginTop: spacing[4],
    minHeight: touchTarget.primary,
    paddingHorizontal: spacing[6],
    borderRadius: 9999,
    backgroundColor: colors.brandDefault,
    alignItems: "center",
    justifyContent: "center",
  },
  buttonText: {
    color: "#fff",
    fontWeight: "700",
  },
  overlay: {
    position: "absolute",
    bottom: spacing[8],
    left: spacing[4],
    right: spacing[4],
    alignItems: "center",
    gap: spacing[2],
  },
  overlayTitle: {
    color: "#fff",
    fontSize: typography.sectionHeading.fontSize,
    fontWeight: typography.sectionHeading.fontWeight,
  },
  errorText: {
    color: "#fff",
    backgroundColor: colors.danger,
    marginTop: spacing[3],
    padding: spacing[3],
    borderRadius: 8,
    textAlign: "center",
  },
  cancelButton: {
    marginTop: spacing[3],
    minHeight: touchTarget.min,
    paddingHorizontal: spacing[6],
    borderRadius: 9999,
    borderWidth: 1,
    borderColor: "#fff",
    alignItems: "center",
    justifyContent: "center",
  },
  cancelButtonText: {
    color: "#fff",
    fontWeight: "600",
  },
});
