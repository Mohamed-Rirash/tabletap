import { useMemo, useState } from "react";
import { Modal, Pressable, ScrollView, StyleSheet, Text, TextInput, View } from "react-native";
import { colors, radius, spacing, touchTarget, typography, type MenuItem } from "@tabletap/shared";

interface Props {
  item: MenuItem | null;
  onClose: () => void;
  onAdd: (item: MenuItem, optionIds: string[], qty: number, notes: string) => void;
  adding: boolean;
}

/**
 * ui-tokens.md "Modifier Sheet (customer)" — a bottom-sheet-shaped
 * modal (React Native's built-in `Modal`, no extra dependency) covering
 * both no-modifier and multi-group items: the qty stepper + Add button
 * footer applies either way, matching `Public.MenuLive`'s own item
 * detail sheet (every tap opens this, unlike the POS fast-path).
 * Selection-completeness is only a client-side UX nicety (disables the
 * button) — `Ordering.add_to_cart/7` is still the real, authoritative
 * validation on submit.
 */
export function ItemDetailSheet({ item, onClose, onAdd, adding }: Props) {
  const [selected, setSelected] = useState<Record<string, string[]>>({});
  const [qty, setQty] = useState(1);
  const [notes, setNotes] = useState("");

  const visible = item !== null;

  const unsatisfiedGroups = useMemo(() => {
    if (!item) return [];
    return item.modifier_groups.filter((group) => {
      const count = selected[group.id]?.length ?? 0;
      return count < group.min_selections;
    });
  }, [item, selected]);

  function toggleOption(groupId: string, optionId: string, max: number) {
    setSelected((prev) => {
      const current = prev[groupId] ?? [];
      const already = current.includes(optionId);
      if (already) return { ...prev, [groupId]: current.filter((id) => id !== optionId) };
      if (max === 1) return { ...prev, [groupId]: [optionId] };
      if (current.length >= max) return prev;
      return { ...prev, [groupId]: [...current, optionId] };
    });
  }

  function reset() {
    setSelected({});
    setQty(1);
    setNotes("");
  }

  function handleClose() {
    reset();
    onClose();
  }

  function handleAdd() {
    if (!item) return;
    const optionIds = Object.values(selected).flat();
    onAdd(item, optionIds, qty, notes);
    reset();
  }

  if (!item) return null;

  return (
    <Modal visible={visible} animationType="slide" transparent onRequestClose={handleClose}>
      <Pressable style={styles.backdrop} onPress={handleClose} />
      <View style={styles.sheet}>
        <ScrollView>
          <Text style={styles.title}>{item.name}</Text>
          {item.description && <Text style={styles.description}>{item.description}</Text>}

          {item.modifier_groups.map((group) => (
            <View key={group.id} style={styles.group}>
              <View style={styles.groupHeader}>
                <Text style={styles.groupName}>{group.name}</Text>
                <Text style={styles.groupHint}>
                  {group.max_selections === 1
                    ? "Choose 1"
                    : `Up to ${group.max_selections}`}
                </Text>
              </View>
              {group.options.map((option) => {
                const isSelected = (selected[group.id] ?? []).includes(option.id);
                return (
                  <Pressable
                    key={option.id}
                    style={styles.optionRow}
                    onPress={() => toggleOption(group.id, option.id, group.max_selections)}
                  >
                    <Text style={styles.optionName}>
                      {isSelected ? "☑" : "☐"} {option.name}
                    </Text>
                    <Text style={styles.optionPrice}>
                      {option.price_delta.amount !== "0.00" &&
                        `+${option.price_delta.currency} ${option.price_delta.amount}`}
                    </Text>
                  </Pressable>
                );
              })}
            </View>
          ))}

          <TextInput
            style={styles.notes}
            placeholder="Notes (optional)"
            value={notes}
            onChangeText={setNotes}
            multiline
          />
        </ScrollView>

        <View style={styles.footer}>
          <View style={styles.stepper}>
            <Pressable onPress={() => setQty((q) => Math.max(1, q - 1))} style={styles.stepBtn}>
              <Text style={styles.stepBtnText}>-</Text>
            </Pressable>
            <Text style={styles.qty}>{qty}</Text>
            <Pressable onPress={() => setQty((q) => q + 1)} style={styles.stepBtn}>
              <Text style={styles.stepBtnText}>+</Text>
            </Pressable>
          </View>
          <Pressable
            style={[
              styles.addButton,
              (unsatisfiedGroups.length > 0 || adding) && styles.addButtonDisabled,
            ]}
            disabled={unsatisfiedGroups.length > 0 || adding}
            onPress={handleAdd}
          >
            <Text style={styles.addButtonText}>{adding ? "Adding…" : "Add"}</Text>
          </Pressable>
        </View>
      </View>
    </Modal>
  );
}

const styles = StyleSheet.create({
  backdrop: {
    flex: 1,
    backgroundColor: "rgba(0,0,0,0.4)",
  },
  sheet: {
    backgroundColor: colors.light.surface,
    borderTopLeftRadius: radius.lg,
    borderTopRightRadius: radius.lg,
    padding: spacing[4],
    maxHeight: "80%",
  },
  title: {
    fontSize: typography.venueName.fontSize,
    fontWeight: typography.venueName.fontWeight,
    color: colors.light.textPrimary,
  },
  description: {
    fontSize: typography.body.fontSize,
    color: colors.light.textSecondary,
    marginTop: spacing[1],
  },
  group: {
    marginTop: spacing[4],
  },
  groupHeader: {
    flexDirection: "row",
    justifyContent: "space-between",
    marginBottom: spacing[2],
  },
  groupName: {
    fontSize: typography.sectionHeading.fontSize,
    fontWeight: typography.sectionHeading.fontWeight,
    color: colors.light.textPrimary,
  },
  groupHint: {
    fontSize: typography.caption.fontSize,
    color: colors.light.textMuted,
  },
  optionRow: {
    flexDirection: "row",
    justifyContent: "space-between",
    minHeight: touchTarget.min,
    alignItems: "center",
  },
  optionName: {
    fontSize: typography.body.fontSize,
    color: colors.light.textPrimary,
  },
  optionPrice: {
    fontSize: typography.caption.fontSize,
    color: colors.light.textSecondary,
  },
  notes: {
    marginTop: spacing[4],
    borderWidth: 1,
    borderColor: colors.light.border,
    borderRadius: radius.md,
    padding: spacing[3],
    minHeight: 56,
  },
  footer: {
    flexDirection: "row",
    gap: spacing[3],
    marginTop: spacing[4],
    alignItems: "center",
  },
  stepper: {
    flexDirection: "row",
    alignItems: "center",
    gap: spacing[3],
  },
  stepBtn: {
    width: touchTarget.min,
    height: touchTarget.min,
    borderRadius: radius.full,
    borderWidth: 1,
    borderColor: colors.light.border,
    alignItems: "center",
    justifyContent: "center",
  },
  stepBtnText: {
    fontSize: 18,
    fontWeight: "700",
  },
  qty: {
    fontSize: typography.itemName.fontSize,
    fontWeight: "700",
    minWidth: 24,
    textAlign: "center",
  },
  addButton: {
    flex: 1,
    height: touchTarget.primary,
    borderRadius: radius.full,
    backgroundColor: colors.brandDefault,
    alignItems: "center",
    justifyContent: "center",
  },
  addButtonDisabled: {
    opacity: 0.5,
  },
  addButtonText: {
    color: "#fff",
    fontWeight: "700",
    fontSize: typography.itemName.fontSize,
  },
});
