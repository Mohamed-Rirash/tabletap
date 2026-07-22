defmodule TabletapWeb.Api.Serializers do
  @moduledoc """
  Plain-map JSON shapes shared by the customer-facing `/api/v1`
  controllers (build-plan.md Feature 23) — small and hand-rolled rather
  than a `phx.gen.json`-style view-module-per-resource setup, matching
  this codebase's existing "no abstraction until a surface needs it"
  discipline. `Money`/`Decimal` values are embedded as structs directly
  (both already implement `Jason.Encoder` — `ex_money`'s own protocol
  impl, confirmed in `deps/ex_money`), never hand-formatted strings.
  """

  alias Tabletap.Catalog

  def menu(categories, scope) do
    daily_limits = Catalog.list_daily_limits(scope)

    %{
      categories:
        Enum.map(categories, fn {category, items} ->
          %{
            id: category.id,
            name: category.name,
            items: Enum.map(items, &menu_item(&1, scope, daily_limits))
          }
        end)
    }
  end

  defp menu_item(item, scope, daily_limits) do
    %{
      id: item.id,
      name: item.name,
      description: item.description,
      photo_url: item.photo_url,
      price: item.price,
      remaining: remaining_for(item, daily_limits),
      dietary_tags: item.dietary_tags,
      allergen_tags: item.allergen_tags,
      modifier_groups:
        scope |> Catalog.list_item_modifier_groups(item) |> Enum.map(&modifier_group/1)
    }
  end

  defp modifier_group(group) do
    %{
      id: group.id,
      name: group.name,
      min_selections: group.min_selections,
      max_selections: group.max_selections,
      required: group.required,
      options: Enum.map(group.options, &modifier_option/1)
    }
  end

  defp modifier_option(option) do
    %{
      id: option.id,
      name: option.name,
      price_delta: option.price_delta,
      default: option.default
    }
  end

  defp remaining_for(item, daily_limits) do
    case Map.get(daily_limits, item.id) do
      nil -> "unlimited"
      limit -> Catalog.DailyItemLimit.remaining(limit)
    end
  end

  def cart(nil), do: nil

  def cart(cart) do
    %{
      guest_token: cart.guest_token,
      kind: cart.kind,
      items: Enum.map(cart.items, &cart_item/1)
    }
  end

  defp cart_item(item) do
    %{
      id: item.id,
      menu_item_id: item.menu_item_id,
      name: item.menu_item.name,
      qty: item.qty,
      notes: item.notes,
      options: Enum.map(item.options, &%{id: &1.id, name: &1.name, price_delta: &1.price_delta})
    }
  end

  @doc "Same shape as `order/3` but without a payment lookup — the owner dashboard's kitchen-floor list doesn't need it, and looking one up per order would be an avoidable N+1."
  def kitchen_order(order, eta_minutes), do: order(order, eta_minutes, nil)

  def order(order, eta_minutes, payment) do
    %{
      id: order.id,
      guest_token: order.guest_token,
      number: order.number,
      status: order.status,
      kind: order.kind,
      subtotal: order.subtotal,
      discount_total: order.discount_total,
      total: order.total,
      eta_minutes: eta_minutes,
      payment: payment && %{provider: payment.provider, status: payment.status},
      flag: order.flag,
      items: Enum.map(order.items, &order_item/1),
      placed_at: order.placed_at,
      accepted_at: order.accepted_at,
      ready_at: order.ready_at,
      served_at: order.served_at
    }
  end

  @doc "build-plan.md Feature 24 — one row of `GET /api/v1/me/history`, deliberately lighter than `order/3` (no items/eta/payment — a flat spend list, same shape `UserLive.History` renders)."
  def history_entry(order) do
    %{
      id: order.id,
      guest_token: order.guest_token,
      number: order.number,
      status: order.status,
      total: order.total,
      venue_name: order.venue.name,
      placed_at: order.placed_at
    }
  end

  @doc "build-plan.md Feature 25 — one row of `GET /api/v1/me/memberships`, the mobile staff app's role-detection/mode-switcher source."
  def membership(m) do
    %{
      membership_id: m.id,
      role: m.role,
      org_id: m.org_id,
      org_name: m.org.name,
      venue_id: m.venue_id,
      venue_name: m.venue && m.venue.name
    }
  end

  defp order_item(item) do
    %{
      id: item.id,
      menu_item_id: item.menu_item_id,
      name: item.name_snapshot,
      qty: item.qty,
      unit_price: item.unit_price_snapshot,
      line_total: item.line_total,
      notes: item.notes,
      modifiers:
        Enum.map(item.modifiers, &%{name: &1.name_snapshot, price_delta: &1.price_delta_snapshot})
    }
  end
end
