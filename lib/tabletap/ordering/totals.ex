defmodule Tabletap.Ordering.Totals do
  @moduledoc """
  The one place order/cart totals are computed (code-standards.md "Order
  totals follow one fixed formula — `total = subtotal − discount_total` —
  implemented in exactly one module; no surface recomputes totals
  locally"). No tax, tip, or service charge anywhere — menu prices are
  final (founder decision, code-standards.md).
  """

  alias Tabletap.Ordering.CartItem

  @doc "One line's total: (item price + selected option deltas) × qty."
  def line_total(%CartItem{} = cart_item) do
    base = cart_item.menu_item.price
    zero = Money.new!(base.currency, 0)
    deltas = Enum.reduce(cart_item.options, zero, &Money.add!(&2, &1.price_delta))
    Money.mult!(Money.add!(base, deltas), cart_item.qty)
  end

  @doc "Sum of `line_total/1` across `cart_items` (callers pass only structurally-valid lines — design-qa.md Q42)."
  def subtotal(cart_items, currency) do
    zero = Money.new!(currency, 0)
    Enum.reduce(cart_items, zero, &Money.add!(&2, line_total(&1)))
  end

  @doc """
  The full `%{subtotal, discount_total, total}` an order snapshots at
  checkout — `total = subtotal − discount_total`, the one fixed formula.

  `discount_total` is always zero for now: no discount-application UI
  exists anywhere in the build plan yet — design-qa.md Q36's
  `order_discounts` attribution table (and the formula's non-zero case)
  lands with whichever feature actually builds one, not speculatively
  here.
  """
  def compute(cart_items, currency) do
    subtotal = subtotal(cart_items, currency)
    discount_total = Money.new!(currency, 0)

    %{
      subtotal: subtotal,
      discount_total: discount_total,
      total: Money.sub!(subtotal, discount_total)
    }
  end
end
