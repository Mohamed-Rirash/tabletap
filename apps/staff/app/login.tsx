import { useState } from "react";
import { Pressable, StyleSheet, Text, TextInput, View } from "react-native";
import { colors, radius, spacing, touchTarget, typography } from "@tabletap/shared";
import { useApi, ApiError } from "../src/api";
import { useCompleteSignIn } from "../src/session";

/**
 * build-plan.md Feature 25 — the staff app's own login screen, deliberately
 * offering both sign-in paths design-qa.md Q47 established: a password
 * (owner/manager set one at account setup so an email delay can never
 * lock them out) or a magic link (waiter/cashier/kitchen stay
 * magic-link-first). `POST /api/v1/auth/request_magic_link`'s `app:
 * "staff"` param mints a `tabletap-staff://auth/:token` deep link, not
 * the customer app's `tabletap://` one — two installed apps can't
 * reliably share one custom URL scheme.
 */
export default function LoginScreen() {
  const api = useApi();
  const completeSignIn = useCompleteSignIn();

  const [email, setEmail] = useState("");
  const [password, setPassword] = useState("");
  const [usePassword, setUsePassword] = useState(true);
  const [sent, setSent] = useState(false);
  const [submitting, setSubmitting] = useState(false);
  const [error, setError] = useState<string | null>(null);

  async function handlePasswordSignIn() {
    setSubmitting(true);
    setError(null);
    try {
      const tokens = await api.login(email, password);
      await completeSignIn(tokens);
    } catch (e) {
      setError(e instanceof ApiError ? e.message : "Something went wrong signing you in.");
    } finally {
      setSubmitting(false);
    }
  }

  async function handleMagicLinkRequest() {
    setSubmitting(true);
    try {
      await api.requestMagicLink(email, "staff");
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
      <Text style={styles.title}>TableTap Staff</Text>
      <TextInput
        style={styles.input}
        placeholder="Email address"
        autoCapitalize="none"
        keyboardType="email-address"
        value={email}
        onChangeText={setEmail}
      />
      {usePassword && (
        <TextInput
          style={styles.input}
          placeholder="Password"
          secureTextEntry
          value={password}
          onChangeText={setPassword}
        />
      )}

      {error && <Text style={styles.errorText}>{error}</Text>}

      <Pressable
        style={[
          styles.button,
          (!email || (usePassword && !password) || submitting) && styles.buttonDisabled,
        ]}
        disabled={!email || (usePassword && !password) || submitting}
        onPress={usePassword ? handlePasswordSignIn : handleMagicLinkRequest}
      >
        <Text style={styles.buttonText}>
          {submitting ? "Signing in…" : usePassword ? "Sign in" : "Send me a login link"}
        </Text>
      </Pressable>

      <Pressable onPress={() => setUsePassword((v) => !v)}>
        <Text style={styles.switchLink}>
          {usePassword ? "Sign in with a login link instead" : "Sign in with a password instead"}
        </Text>
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
  },
  button: {
    marginTop: spacing[3],
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
  switchLink: {
    marginTop: spacing[2],
    textAlign: "center",
    color: colors.brandDefault,
    fontSize: typography.caption.fontSize,
  },
  errorText: {
    color: "#fff",
    backgroundColor: colors.danger,
    borderRadius: radius.md,
    padding: spacing[3],
    textAlign: "center",
  },
});
