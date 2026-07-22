import { StyleSheet, Text, View } from "react-native";
import { colors, spacing, typography } from "@tabletap/shared";

export default function Index() {
  return (
    <View style={styles.container}>
      <Text style={styles.title}>TableTap</Text>
      <Text style={styles.body}>Scan a table QR to start ordering.</Text>
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
  },
});
