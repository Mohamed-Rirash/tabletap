import { useState } from "react";
import { Pressable, StyleSheet, Text, TextInput, View } from "react-native";
import { colors, radius, spacing, touchTarget, typography } from "@tabletap/shared";
import { api } from "../src/api";

/**
 * build-plan.md Feature 24 Commit 5 — the customer-facing magic-link
 * request screen. Completing the link happens in `app/auth/[token].tsx`
 * (the `tabletap://auth/:token` deep link Feature 23 Commit 1 already
 * mints), not here — this screen only sends the email.
 */
export default function LoginScreen() {
  const [email, setEmail] = useState("");
  const [sent, setSent] = useState(false);
  const [submitting, setSubmitting] = useState(false);

  async function handleSubmit() {
    setSubmitting(true);
    try {
      await api.requestMagicLink(email);
      setSent(true);
    } finally {
      setSubmitting(false);
    }
  }

  if (sent) {
    return (
      <View style={styles.container}>
        <Text style={styles.title}>Check your email</Text>
        <Text style={styles.body}>
          If that email is in our system, a login link is on its way — tap it on this device to
          sign in.
        </Text>
      </View>
    );
  }

  return (
    <View style={styles.container}>
      <Text style={styles.title}>Sign in</Text>
      <Text style={styles.body}>See your order history and spend across every venue.</Text>
      <TextInput
        style={styles.input}
        placeholder="Email address"
        autoCapitalize="none"
        keyboardType="email-address"
        value={email}
        onChangeText={setEmail}
      />
      <Pressable
        style={[styles.button, (!email || submitting) && styles.buttonDisabled]}
        disabled={!email || submitting}
        onPress={handleSubmit}
      >
        <Text style={styles.buttonText}>{submitting ? "Sending…" : "Send me a login link"}</Text>
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
  input: {
    borderWidth: 1,
    borderColor: colors.light.border,
    borderRadius: radius.md,
    padding: spacing[3],
    minHeight: touchTarget.min,
    marginTop: spacing[3],
  },
  button: {
    marginTop: spacing[4],
    height: touchTarget.primary,
    borderRadius: radius.full,
    backgroundColor: colors.brandDefault,
    alignItems: "center",
    justifyContent: "center",
  },
  buttonDisabled: {
    opacity: 0.5,
  },
  buttonText: {
    color: "#fff",
    fontWeight: "700",
  },
});
