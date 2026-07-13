defmodule Tabletap.Ordering.TotalsTest do
  @moduledoc """
  Hand-computed cases across a range of realistic scenarios (build-plan.md
  Feature 08: "Totals engine ... property-tested against hand-computed
  cases" — no property-testing dependency is on code-standards.md's
  approved list, so this is the equivalent discipline: every case's
  expected total is computed independently, by hand, in the test itself).
  """
  use ExUnit.Case, async: true

  alias Tabletap.Catalog.{MenuItem, ModifierOption}
  alias Tabletap.Ordering.{CartItem, Totals}

  # A preloaded %CartItem{} built in-memory (no Repo call needed) —
  # Totals only ever reads .menu_item.price, .options (each
  # .price_delta), and .qty.
  defp line(price, deltas, qty) do
    %CartItem{
      menu_item: %MenuItem{price: price},
      options: Enum.map(deltas, &%ModifierOption{price_delta: &1}),
      qty: qty
    }
  end

  describe "line_total/1" do
    test "base price only, qty 1" do
      assert Money.equal?(
               Totals.line_total(line(Money.new!(:USD, "5.00"), [], 1)),
               Money.new!(:USD, "5.00")
             )
    end

    test "base price with one positive delta" do
      line = line(Money.new!(:USD, "5.00"), [Money.new!(:USD, "1.00")], 1)
      assert Money.equal?(Totals.line_total(line), Money.new!(:USD, "6.00"))
    end

    test "base price with a negative delta (a removal-style option with a discount)" do
      line = line(Money.new!(:USD, "5.00"), [Money.new!(:USD, "-0.50")], 1)
      assert Money.equal?(Totals.line_total(line), Money.new!(:USD, "4.50"))
    end

    test "multiple deltas summed before multiplying by qty" do
      # (5.00 + 1.00 + 0.50) * 3 = 19.50 — not 5.00*3 + 1.00 + 0.50 (14.50).
      line =
        line(Money.new!(:USD, "5.00"), [Money.new!(:USD, "1.00"), Money.new!(:USD, "0.50")], 3)

      assert Money.equal?(Totals.line_total(line), Money.new!(:USD, "19.50"))
    end

    test "zero-delta options don't change the total" do
      line = line(Money.new!(:USD, "3.50"), [Money.new!(:USD, "0.00")], 2)
      assert Money.equal?(Totals.line_total(line), Money.new!(:USD, "7.00"))
    end

    test "a free ($0) item with qty 1 totals zero" do
      assert Money.equal?(
               Totals.line_total(line(Money.new!(:USD, "0.00"), [], 1)),
               Money.new!(:USD, "0.00")
             )
    end
  end

  describe "subtotal/2" do
    test "sums multiple lines" do
      lines = [
        line(Money.new!(:USD, "5.00"), [], 1),
        line(Money.new!(:USD, "2.00"), [Money.new!(:USD, "0.50")], 2)
      ]

      # 5.00 + (2.00 + 0.50) * 2 = 5.00 + 5.00 = 10.00
      assert Money.equal?(Totals.subtotal(lines, :USD), Money.new!(:USD, "10.00"))
    end

    test "an empty cart totals zero" do
      assert Money.equal?(Totals.subtotal([], :USD), Money.new!(:USD, "0.00"))
    end
  end

  describe "compute/2" do
    test "total = subtotal - discount_total, with discount_total always zero for now" do
      lines = [line(Money.new!(:USD, "5.00"), [Money.new!(:USD, "1.00")], 2)]

      # (5.00 + 1.00) * 2 = 12.00
      assert %{subtotal: subtotal, discount_total: discount_total, total: total} =
               Totals.compute(lines, :USD)

      assert Money.equal?(subtotal, Money.new!(:USD, "12.00"))
      assert Money.equal?(discount_total, Money.new!(:USD, "0.00"))
      assert Money.equal?(total, Money.new!(:USD, "12.00"))
      assert Money.equal?(total, Money.sub!(subtotal, discount_total))
    end

    test "an all-free order (every item and option $0) computes to zero — the comp-settlement edge case" do
      lines = [line(Money.new!(:USD, "0.00"), [Money.new!(:USD, "0.00")], 5)]

      assert %{total: total} = Totals.compute(lines, :USD)
      assert Money.equal?(total, Money.new!(:USD, "0.00"))
    end

    test "ETB currency, no cross-currency leakage" do
      lines = [line(Money.new!(:ETB, "50.00"), [], 1)]
      assert %{total: total} = Totals.compute(lines, :ETB)
      assert total.currency == :ETB
      assert Money.equal?(total, Money.new!(:ETB, "50.00"))
    end
  end
end
