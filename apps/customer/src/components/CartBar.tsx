import { Pressable, StyleSheet, Text, View } from "react-native";
import { colors, radius, spacing, touchTarget, typography, type Cart } from "@tabletap/shared";

interface Props {
  cart: Cart;
  onPress: () => void;
}

/** ui-tokens.md "Sticky Cart Bar (customer)" — fixed bottom, brand-colored, item count + total. */
export function CartBar({ cart, onPress }: Props) {
  const itemCount = cart.items.reduce((sum, line) => sum + line.qty, 0);
  if (itemCount === 0) return null;

  return (
    <Pressable style={styles.bar} onPress={onPress}>
      <View style={styles.badge}>
        <Text style={styles.badgeText}>{itemCount}</Text>
      </View>
      <Text style={styles.label}>View cart</Text>
    </Pressable>
  );
}

const styles = StyleSheet.create({
  bar: {
    position: "absolute",
    left: spacing[4],
    right: spacing[4],
    bottom: spacing[4],
    height: touchTarget.primary,
    borderRadius: radius.full,
    backgroundColor: colors.brandDefault,
    flexDirection: "row",
    alignItems: "center",
    justifyContent: "center",
    gap: spacing[2],
  },
  badge: {
    backgroundColor: "rgba(255,255,255,0.2)",
    borderRadius: radius.full,
    paddingHorizontal: spacing[2],
    paddingVertical: 2,
  },
  badgeText: {
    color: "#fff",
    fontWeight: "700",
    fontSize: typography.caption.fontSize,
  },
  label: {
    color: "#fff",
    fontWeight: "700",
    fontSize: typography.itemName.fontSize,
  },
});
