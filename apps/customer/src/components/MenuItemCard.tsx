import { Image, Pressable, StyleSheet, Text, View } from "react-native";
import { colors, radius, spacing, typography, type MenuItem } from "@tabletap/shared";

interface Props {
  item: MenuItem;
  onPress: (item: MenuItem) => void;
}

/** ui-tokens.md "Menu Item Card (customer)" — horizontal, text left, 96x96 photo right. */
export function MenuItemCard({ item, onPress }: Props) {
  const soldOut = item.remaining !== "unlimited" && item.remaining <= 0;

  return (
    <Pressable
      onPress={() => !soldOut && onPress(item)}
      disabled={soldOut}
      style={[styles.card, soldOut && styles.cardSoldOut]}
    >
      <View style={styles.text}>
        <Text style={styles.name}>{item.name}</Text>
        {item.description && (
          <Text style={styles.description} numberOfLines={2}>
            {item.description}
          </Text>
        )}
        <Text style={styles.price}>
          {item.price.currency} {item.price.amount}
        </Text>
        {soldOut && (
          <View style={styles.soldOutChip}>
            <Text style={styles.soldOutText}>Sold out</Text>
          </View>
        )}
      </View>
      {item.photo_url && (
        <Image
          source={{ uri: item.photo_url }}
          style={[styles.photo, soldOut && styles.photoSoldOut]}
        />
      )}
    </Pressable>
  );
}

const styles = StyleSheet.create({
  card: {
    flexDirection: "row",
    backgroundColor: colors.light.surface,
    borderWidth: 1,
    borderColor: colors.light.border,
    borderRadius: radius.lg,
    padding: spacing[4],
    gap: spacing[3],
    marginBottom: spacing[3],
  },
  cardSoldOut: {
    opacity: 0.6,
  },
  text: {
    flex: 1,
    gap: spacing[1],
  },
  name: {
    fontSize: typography.itemName.fontSize,
    fontWeight: typography.itemName.fontWeight,
    color: colors.light.textPrimary,
  },
  description: {
    fontSize: typography.body.fontSize,
    color: colors.light.textSecondary,
  },
  price: {
    fontSize: typography.price.fontSize,
    fontWeight: typography.price.fontWeight,
    color: colors.brandDefault,
  },
  photo: {
    width: 96,
    height: 96,
    borderRadius: radius.md,
  },
  photoSoldOut: {
    opacity: 0.5,
  },
  soldOutChip: {
    alignSelf: "flex-start",
    backgroundColor: colors.danger,
    borderRadius: radius.full,
    paddingHorizontal: spacing[2],
    paddingVertical: 2,
  },
  soldOutText: {
    color: "#fff",
    fontSize: typography.caption.fontSize,
    fontWeight: "600",
  },
});
