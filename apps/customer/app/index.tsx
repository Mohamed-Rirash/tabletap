import { useState } from "react";
import { StyleSheet, Text, View, Pressable, ActivityIndicator } from "react-native";
import { CameraView, useCameraPermissions, type BarcodeScanningResult } from "expo-camera";
import { useRouter } from "expo-router";
import { colors, spacing, typography, touchTarget, extractQrToken } from "@tabletap/shared";
import { api } from "../src/api";
import { useCartStore } from "../src/store/cartStore";

export default function ScanScreen() {
  const [permission, requestPermission] = useCameraPermissions();
  const [resolving, setResolving] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [scannedOnce, setScannedOnce] = useState(false);
  const router = useRouter();
  const setTable = useCartStore((s) => s.setTable);

  async function handleScan(result: BarcodeScanningResult) {
    if (scannedOnce || resolving) return;
    setScannedOnce(true);
    setError(null);

    const qrToken = extractQrToken(result.data);
    if (!qrToken) {
      setError("That doesn't look like a TableTap table QR.");
      setScannedOnce(false);
      return;
    }

    setResolving(true);
    try {
      const { venue_slug, table_id } = await api.getTable(qrToken);
      setTable(venue_slug, table_id);
      router.push({ pathname: "/venues/[slug]/menu", params: { slug: venue_slug } });
    } catch {
      setError("We couldn't find that table. Ask staff for a fresh QR code.");
    } finally {
      setResolving(false);
      setScannedOnce(false);
    }
  }

  if (!permission) {
    return <View style={styles.container} />;
  }

  if (!permission.granted) {
    return (
      <View style={styles.container}>
        <Text style={styles.title}>TableTap</Text>
        <Text style={styles.body}>We need camera access to scan your table&apos;s QR code.</Text>
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
        <Text style={styles.overlayTitle}>Scan your table&apos;s QR code</Text>
        {resolving && <ActivityIndicator color="#fff" style={{ marginTop: spacing[3] }} />}
        {error && <Text style={styles.errorText}>{error}</Text>}
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
  title: {
    fontSize: typography.venueName.fontSize,
    fontWeight: typography.venueName.fontWeight,
    color: colors.light.textPrimary,
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
});
