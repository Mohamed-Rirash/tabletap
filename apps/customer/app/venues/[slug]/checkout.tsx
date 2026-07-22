import { useState } from "react";
import { useLocalSearchParams, useRouter } from "expo-router";
import { Pressable, ScrollView, StyleSheet, Text, TextInput, View } from "react-native";
import { colors, radius, spacing, touchTarget, typography } from "@tabletap/shared";
import { api, ApiError } from "../../../src/api";
import { useCartStore } from "../../../src/store/cartStore";

/**
 * build-plan.md Feature 24 Commit 4 — "wallet checkout (enter wallet
 * number → live payment state while the PIN prompt is approved on the
 * phone)". Wallet-only, matching build-plan's own wording for this
 * screen (cash/pay-at-counter is a POS/web surface, not named here).
 * `Ordering.checkout/2` never charges payment itself — the created
 * order is already durable the instant this call returns; the actual
 * wallet charge resolves live on the tracker screen this navigates to,
 * exactly the same two-step shape the web checkout uses.
 */
export default function CheckoutScreen() {
  const { slug } = useLocalSearchParams<{ slug: string }>();
  const router = useRouter();
  const cart = useCartStore((s) => s.cart);
  const guestToken = useCartStore((s) => s.guestToken);
  const clearCart = useCartStore((s) => s.clear);

  const [walletMsisdn, setWalletMsisdn] = useState("");
  const [submitting, setSubmitting] = useState(false);
  const [error, setError] = useState<string | null>(null);

  async function handlePlaceOrder() {
    if (!guestToken) return;
    setSubmitting(true);
    setError(null);
    try {
      const order = await api.checkout({
        venue_slug: slug,
        guest_token: guestToken,
        payment_method: "wallet",
        wallet_msisdn: walletMsisdn,
      });
      clearCart();
      router.replace({
        pathname: "/orders/[guestToken]",
        params: { guestToken: order.guest_token },
      });
    } catch (e) {
      setError(e instanceof ApiError ? e.message : "Something went wrong placing your order.");
    } finally {
      setSubmitting(false);
    }
  }

  if (!cart || cart.items.length === 0) {
    return (
      <View style={styles.center}>
        <Text style={styles.body}>Your cart is empty.</Text>
      </View>
    );
  }

  return (
    <ScrollView contentContainerStyle={styles.container}>
      <Text style={styles.title}>Your order</Text>
      {cart.items.map((line) => (
        <View key={line.id} style={styles.line}>
          <Text style={styles.lineName}>
            {line.qty}× {line.name}
          </Text>
        </View>
      ))}

      <Text style={styles.sectionTitle}>Pay with wallet</Text>
      <TextInput
        style={styles.input}
        placeholder="Wallet number"
        keyboardType="phone-pad"
        value={walletMsisdn}
        onChangeText={setWalletMsisdn}
      />
      <Text style={styles.hint}>Approve the PIN prompt on your phone once it arrives.</Text>

      {error && <Text style={styles.errorText}>{error}</Text>}

      <Pressable
        style={[styles.payButton, (submitting || !walletMsisdn) && styles.payButtonDisabled]}
        disabled={submitting || !walletMsisdn}
        onPress={handlePlaceOrder}
      >
        <Text style={styles.payButtonText}>{submitting ? "Placing order…" : "Place order"}</Text>
      </Pressable>
    </ScrollView>
  );
}

const styles = StyleSheet.create({
  container: {
    padding: spacing[4],
    backgroundColor: colors.light.background,
  },
  center: {
    flex: 1,
    alignItems: "center",
    justifyContent: "center",
    backgroundColor: colors.light.background,
  },
  title: {
    fontSize: typography.venueName.fontSize,
    fontWeight: typography.venueName.fontWeight,
    color: colors.light.textPrimary,
    marginBottom: spacing[3],
  },
  line: {
    paddingVertical: spacing[2],
  },
  lineName: {
    fontSize: typography.body.fontSize,
    color: colors.light.textPrimary,
  },
  sectionTitle: {
    fontSize: typography.sectionHeading.fontSize,
    fontWeight: typography.sectionHeading.fontWeight,
    color: colors.light.textPrimary,
    marginTop: spacing[6],
    marginBottom: spacing[3],
  },
  input: {
    borderWidth: 1,
    borderColor: colors.light.border,
    borderRadius: radius.md,
    padding: spacing[3],
    minHeight: touchTarget.min,
  },
  hint: {
    fontSize: typography.caption.fontSize,
    color: colors.light.textMuted,
    marginTop: spacing[2],
  },
  body: {
    fontSize: typography.body.fontSize,
    color: colors.light.textSecondary,
  },
  errorText: {
    color: "#fff",
    backgroundColor: colors.danger,
    borderRadius: radius.md,
    padding: spacing[3],
    marginTop: spacing[4],
    textAlign: "center",
  },
  payButton: {
    marginTop: spacing[6],
    height: touchTarget.primary,
    borderRadius: radius.full,
    backgroundColor: colors.brandDefault,
    alignItems: "center",
    justifyContent: "center",
  },
  payButtonDisabled: {
    opacity: 0.5,
  },
  payButtonText: {
    color: "#fff",
    fontWeight: "700",
    fontSize: typography.itemName.fontSize,
  },
});
