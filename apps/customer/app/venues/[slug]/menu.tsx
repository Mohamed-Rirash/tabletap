import { useEffect, useState } from "react";
import { useLocalSearchParams } from "expo-router";
import { ActivityIndicator, ScrollView, StyleSheet, Text, View } from "react-native";
import { colors, spacing, typography, type Menu, type MenuItem } from "@tabletap/shared";
import { api } from "../../../src/api";
import { useCartStore } from "../../../src/store/cartStore";
import { MenuItemCard } from "../../../src/components/MenuItemCard";
import { ItemDetailSheet } from "../../../src/components/ItemDetailSheet";
import { CartBar } from "../../../src/components/CartBar";

export default function MenuScreen() {
  const { slug } = useLocalSearchParams<{ slug: string }>();
  const [menu, setMenu] = useState<Menu | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [selectedItem, setSelectedItem] = useState<MenuItem | null>(null);
  const [adding, setAdding] = useState(false);

  const tableId = useCartStore((s) => s.tableId);
  const guestToken = useCartStore((s) => s.guestToken);
  const cart = useCartStore((s) => s.cart);
  const setCart = useCartStore((s) => s.setCart);

  useEffect(() => {
    let cancelled = false;
    api
      .getMenu(slug)
      .then((data) => !cancelled && setMenu(data))
      .catch(() => !cancelled && setError("Couldn't load the menu — check your connection."));
    return () => {
      cancelled = true;
    };
  }, [slug]);

  async function handleAdd(item: MenuItem, optionIds: string[], qty: number, notes: string) {
    setAdding(true);
    try {
      const result = await api.addToCart(slug, {
        item_id: item.id,
        qty,
        option_ids: optionIds,
        notes: notes || undefined,
        guest_token: guestToken ?? undefined,
        table_id: tableId ?? undefined,
      });
      setCart(result.cart);
      setSelectedItem(null);
    } catch {
      setError("Couldn't add that item — it may have just sold out.");
    } finally {
      setAdding(false);
    }
  }

  if (error) {
    return (
      <View style={styles.center}>
        <Text style={styles.errorText}>{error}</Text>
      </View>
    );
  }

  if (!menu) {
    return (
      <View style={styles.center}>
        <ActivityIndicator />
      </View>
    );
  }

  return (
    <View style={styles.container}>
      <ScrollView contentContainerStyle={styles.scrollContent}>
        {menu.categories.map((category) => (
          <View key={category.id} style={styles.category}>
            <Text style={styles.categoryName}>{category.name}</Text>
            {category.items.map((item) => (
              <MenuItemCard key={item.id} item={item} onPress={setSelectedItem} />
            ))}
          </View>
        ))}
      </ScrollView>

      <ItemDetailSheet
        item={selectedItem}
        onClose={() => setSelectedItem(null)}
        onAdd={handleAdd}
        adding={adding}
      />

      {/* Checkout screen lands in build-plan.md Feature 24 Commit 4 —
          the cart bar itself is real and live-updating now, its
          navigation target isn't built yet. */}
      {cart && <CartBar cart={cart} onPress={() => {}} />}
    </View>
  );
}

const styles = StyleSheet.create({
  container: {
    flex: 1,
    backgroundColor: colors.light.background,
  },
  scrollContent: {
    padding: spacing[4],
    paddingBottom: 96,
  },
  category: {
    marginBottom: spacing[6],
  },
  categoryName: {
    fontSize: typography.sectionHeading.fontSize,
    fontWeight: typography.sectionHeading.fontWeight,
    color: colors.light.textPrimary,
    marginBottom: spacing[3],
  },
  center: {
    flex: 1,
    alignItems: "center",
    justifyContent: "center",
    backgroundColor: colors.light.background,
  },
  errorText: {
    fontSize: typography.body.fontSize,
    color: colors.light.textSecondary,
    textAlign: "center",
    paddingHorizontal: spacing[6],
  },
});
