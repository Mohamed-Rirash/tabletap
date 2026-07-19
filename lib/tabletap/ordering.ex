defmodule Tabletap.Ordering do
  @moduledoc """
  Guest carts and orders (architecture.md "ordering/" context;
  build-plan.md Features 07/08). Waiter assignment lands in Feature 10.

  Every function takes `%Scope{}` first, same as `Catalog`. The public
  customer path builds its scope exactly like `Public.MenuLive` already
  does: `%Scope{org: venue.org, venue: venue, role: :guest}` — there is
  no authenticated user, so `scope.venue` is the sole source of tenant
  identity here (never `skip_org_id: true` — `Ordering` isn't on that
  exception list, code-standards.md "Tenancy Rules").

  Carts are always **live-computed**, never snapshotted — `cart_total/2`
  and `line_total/1` read the menu's *current* price and option deltas on
  every call. `checkout/2` is the one-way door: it freezes those live
  numbers into `Order`/`OrderItem`/`OrderItemModifier` snapshots
  (code-standards.md "Snapshots over joins for history") and the cart
  itself is marked `:converted`, never touched again.
  """

  import Ecto.Query, warn: false

  alias Tabletap.Accounts
  alias Tabletap.Accounts.Scope
  alias Tabletap.Catalog
  alias Tabletap.Catalog.{DailyItemLimit, MenuItem}
  alias Tabletap.Ordering.{Cart, CartItem, CartItemOption, Order, OrderDiscount, OrderItem}
  alias Tabletap.Ordering.{OrderItemModifier, OrderNumberCounter, OrderStateMachine}
  alias Tabletap.Ordering.{Totals, WaiterCall}
  alias Tabletap.Ordering.Workers.EscalateUnacceptedOrder
  alias Tabletap.Payments
  alias Tabletap.Repo
  alias Tabletap.Tenants
  alias Tabletap.Tenants.{Membership, Venue}

  ## Reading a guest's cart

  @doc """
  The guest's active cart at this venue, items/menu-item/options
  preloaded — `nil` if they haven't added anything yet (no cart row
  exists until the first `add_to_cart/6`, architecture.md "guest_token
  minted on first add"). The caller (the menu/cart LiveView) rebuilds
  from here on every mount, so reconnects and deploys lose nothing
  (design-qa.md Q50).
  """
  def get_active_cart(%Scope{venue: venue}, guest_token) when is_binary(guest_token) do
    Repo.one(
      from(c in Cart,
        where: c.guest_token == ^guest_token and c.venue_id == ^venue.id and c.status == :active,
        preload: [items: ^items_preload_query()]
      )
    )
  end

  def get_active_cart(%Scope{}, nil), do: nil

  defp items_preload_query do
    from(i in CartItem, order_by: i.inserted_at, preload: [:menu_item, options: :group])
  end

  ## Adding

  @doc """
  Adds one line to the guest's cart, creating the cart itself if this is
  their first add at this venue. `option_ids` is validated against the
  item's *currently* attached modifier groups (same structural rules
  `validate_line/2` re-checks later — design-qa.md Q42) before anything
  is written, so a bad selection never reaches the database.

  Returns `{:ok, cart}` (freshly reloaded) or:
  - `{:error, :item_unavailable}` — inactive, unavailable today,
    archived, or today's daily limit is exhausted
  - `{:error, :options_changed}` — a selected option isn't currently
    offered, or a group's min/max isn't satisfied (the same check and
    the same atom `validate_line/2` returns on later revalidation)
  - `{:error, changeset}` — qty/notes validation failure
  """
  def add_to_cart(
        %Scope{org: org, venue: venue} = scope,
        guest_token,
        table_id,
        %MenuItem{} = item,
        option_ids,
        qty,
        notes
      )
      when is_binary(guest_token) and is_list(option_ids) do
    with :ok <- validate_item_orderable(scope, item),
         groups <- Catalog.list_item_modifier_groups(scope, item),
         :ok <- validate_selection(groups, MapSet.new(option_ids)) do
      Ecto.Multi.new()
      |> Ecto.Multi.run(:cart, fn _repo, _changes ->
        find_or_create_cart(org, venue, table_id, guest_token)
      end)
      |> Ecto.Multi.insert(:cart_item, fn %{cart: cart} ->
        %CartItem{org_id: org.id, cart_id: cart.id, menu_item_id: item.id}
        |> CartItem.creation_changeset(%{"qty" => qty, "notes" => notes})
      end)
      |> attach_options(org, option_ids)
      |> Repo.transaction()
      |> case do
        {:ok, _changes} -> {:ok, get_active_cart(scope, guest_token)}
        {:error, :cart, reason, _changes} -> {:error, reason}
        {:error, :cart_item, changeset, _changes} -> {:error, changeset}
      end
    end
  end

  defp attach_options(multi, org, option_ids) do
    Enum.reduce(option_ids, multi, fn option_id, multi ->
      Ecto.Multi.insert(multi, {:cart_item_option, option_id}, fn %{cart_item: cart_item} ->
        %CartItemOption{org_id: org.id, cart_item_id: cart_item.id, option_id: option_id}
        |> CartItemOption.creation_changeset()
      end)
    end)
  end

  defp find_or_create_cart(org, venue, table_id, guest_token) do
    case active_cart_query(venue, guest_token) |> Repo.one() do
      %Cart{} = cart -> {:ok, cart}
      nil -> insert_cart(org, venue, table_id, guest_token)
    end
  end

  defp insert_cart(org, venue, table_id, guest_token) do
    case Cart.new_changeset(org.id, venue.id, table_id, guest_token) |> Repo.insert() do
      {:ok, cart} -> {:ok, cart}
      # Lost a race with a concurrent add-to-cart for the same guest+venue
      # (two tabs, same not-yet-cookied guest_token) — the other insert
      # won; use its row rather than erroring the whole request.
      {:error, _changeset} -> recover_from_race(venue, guest_token)
    end
  end

  defp recover_from_race(venue, guest_token) do
    case active_cart_query(venue, guest_token) |> Repo.one() do
      %Cart{} = cart -> {:ok, cart}
      nil -> {:error, :cart_unavailable}
    end
  end

  defp active_cart_query(venue, guest_token) do
    from(c in Cart,
      where: c.guest_token == ^guest_token and c.venue_id == ^venue.id and c.status == :active
    )
  end

  defp validate_item_orderable(%Scope{} = scope, %MenuItem{} = item) do
    cond do
      item.archived_at || !item.active || !item.available_today -> {:error, :item_unavailable}
      sold_out?(scope, item) -> {:error, :item_unavailable}
      true -> :ok
    end
  end

  defp sold_out?(%Scope{} = scope, %MenuItem{} = item) do
    case Catalog.get_daily_limit(scope, item) do
      nil -> false
      limit -> DailyItemLimit.remaining(limit) <= 0
    end
  end

  ## Editing / removing

  def update_item(%Scope{}, %CartItem{} = cart_item, attrs) do
    cart_item |> CartItem.update_changeset(attrs) |> Repo.update()
  end

  def remove_item(%Scope{}, %CartItem{} = cart_item) do
    Repo.delete(cart_item)
    :ok
  end

  @doc "Dine-in vs takeaway (build-plan.md Feature 07) — plus `:counter` for a cashier-built walk-in ticket (Feature 15)."
  def set_kind(%Scope{}, %Cart{} = cart, kind) when kind in [:dine_in, :takeaway, :counter] do
    cart |> Cart.kind_changeset(kind) |> Repo.update()
  end

  ## Structural validity (design-qa.md Q42) — re-checked live, never cached

  @doc """
  Whether `cart_item`'s selections still satisfy the item's *current*
  modifier rules — a group's min/max/required can change, or a group can
  be detached entirely, after the line was added. `:ok`, or
  `{:error, :item_unavailable}` / `{:error, :options_changed}` (never a
  crash on a structurally stale line — Q42's "please re-add," not a
  mis-configured order).
  """
  def validate_line(%Scope{} = scope, %CartItem{} = cart_item) do
    item = cart_item.menu_item

    case validate_item_orderable(scope, item) do
      :ok ->
        groups = Catalog.list_item_modifier_groups(scope, item)
        selected_ids = cart_item.options |> Enum.map(& &1.id) |> MapSet.new()
        validate_selection(groups, selected_ids)

      error ->
        error
    end
  end

  defp validate_selection(groups, selected_ids) do
    valid_ids =
      groups
      |> Enum.flat_map(& &1.options)
      |> Enum.filter(& &1.active)
      |> Enum.map(& &1.id)
      |> MapSet.new()

    cond do
      not MapSet.subset?(selected_ids, valid_ids) -> {:error, :options_changed}
      unsatisfied_groups(groups, selected_ids) != [] -> {:error, :options_changed}
      true -> :ok
    end
  end

  @doc """
  Which of `groups` don't currently have enough (or have too many)
  selections in `selected_ids` — the item detail sheet uses this to turn
  a group's requirement chip red only after a submit attempt (ui-tokens.md
  "Modifier Sheet"), and it's the same rule `validate_selection/2` (and
  therefore `add_to_cart/7`/`validate_line/2`) enforces server-side.
  """
  def unsatisfied_groups(groups, selected_ids) do
    Enum.reject(groups, &group_satisfied?(&1, selected_ids))
  end

  defp group_satisfied?(group, selected_ids) do
    count =
      group.options
      |> Enum.filter(& &1.active)
      |> Enum.count(&MapSet.member?(selected_ids, &1.id))

    count >= group.min_selections and count <= group.max_selections
  end

  ## Pricing — always live (see moduledoc). The actual math lives in
  ## Totals (code-standards.md "implemented in exactly one module") —
  ## these delegate, keeping this module's already-shipped public API
  ## (Feature 07) stable.

  @doc "One line's total: (item price + selected option deltas) × qty."
  defdelegate line_total(cart_item), to: Totals

  @doc "The cart's live total across its structurally-valid lines only — an invalid line never counts toward what the customer would pay (Q42)."
  def cart_total(%Scope{venue: venue} = scope, %Cart{} = cart) do
    cart.items
    |> Enum.filter(&(validate_line(scope, &1) == :ok))
    |> Totals.subtotal(venue.currency)
  end

  ## Checkout (build-plan.md Feature 08) — the one-way door from a live
  ## cart to a snapshotted, held `pending_payment` order.

  @max_active_orders_per_guest 5

  @doc """
  Converts `cart` into a `pending_payment` order — one atomic
  transaction: re-revalidates every line (Q42, in case time passed since
  the cart view last checked), atomically holds daily-limit stock per
  line (Q1 — a DB-level `UPDATE ... WHERE`, never read-then-write),
  reserves the next business-day order number (Q39), snapshots
  `Order`/`OrderItem`/`OrderItemModifier`, and marks the cart
  `:converted`. If any hold fails, the whole transaction rolls back —
  partial holds from earlier lines in the same checkout never strand.

  Gated first, before any of that: the venue must be open
  (`Tenants.venue_open?/2`), not Busy-Mode-paused (Q2), the cart
  non-empty, and the guest under their active-order cap (Q33 — the real
  rate limit; the IP-level cap only throttles token minting, handled at
  the plug layer).

  Returns `{:ok, order}` (items preloaded) or:
  - `{:error, :venue_closed}` / `{:error, :ordering_paused}`
  - `{:error, :empty_cart}` / `{:error, :too_many_active_orders}`
  - `{:error, :items_changed}` — a line failed Q42 revalidation; the
    cart is untouched, the customer fixes it and retries
  - `{:error, :sold_out}` — the atomic hold failed for some line
  """
  def checkout(%Scope{venue: venue} = scope, %Cart{} = cart) do
    with :ok <- check_venue_open(venue),
         :ok <- check_not_paused(venue),
         :ok <- check_not_empty(cart),
         :ok <- check_active_order_cap(scope, cart.guest_token),
         :ok <- check_all_lines_valid(scope, cart) do
      do_checkout(scope, cart)
    end
  end

  defp check_venue_open(venue) do
    if Tenants.venue_open?(venue), do: :ok, else: {:error, :venue_closed}
  end

  defp check_not_paused(venue) do
    if Venue.paused?(venue), do: {:error, :ordering_paused}, else: :ok
  end

  defp check_not_empty(%Cart{items: []}), do: {:error, :empty_cart}
  defp check_not_empty(%Cart{}), do: :ok

  defp check_active_order_cap(%Scope{venue: venue}, guest_token) do
    terminal = [:closed, :expired, :cancelled, :refunded]

    count =
      Repo.aggregate(
        from(o in Order,
          where:
            o.guest_token == ^guest_token and o.venue_id == ^venue.id and
              o.status not in ^terminal
        ),
        :count
      )

    if count >= @max_active_orders_per_guest, do: {:error, :too_many_active_orders}, else: :ok
  end

  defp check_all_lines_valid(scope, %Cart{items: items}) do
    if Enum.all?(items, &(validate_line(scope, &1) == :ok)),
      do: :ok,
      else: {:error, :items_changed}
  end

  defp do_checkout(%Scope{org: org, venue: venue, membership: membership}, cart) do
    business_date = Tenants.business_date(venue)
    totals = Totals.compute(cart.items, venue.currency)

    lines = Enum.map(cart.items, &{&1.menu_item.id, &1.qty})

    Ecto.Multi.new()
    |> Ecto.Multi.run(:holds, fn _repo, _changes ->
      reserve_holds(lines, venue.id, business_date)
    end)
    |> Ecto.Multi.run(:number, fn _repo, _changes ->
      reserve_order_number(org.id, venue.id, business_date)
    end)
    |> Ecto.Multi.insert(:order, fn %{number: number} ->
      Order.new_changeset(%{
        org_id: org.id,
        venue_id: venue.id,
        table_id: cart.table_id,
        guest_token: cart.guest_token,
        # design-qa.md "cashier as full customer proxy": a staff member's
        # own scope carries a membership, a customer's own scope never
        # does (%Scope{role: :guest, membership: nil}) — so this is `nil`
        # for a customer's own QR checkout and set automatically whenever
        # staff place the order on someone's behalf (build-plan.md
        # Feature 15's owner-dashboard.md "Assisted orders report").
        placed_by_membership_id: membership && membership.id,
        number: number,
        business_date: business_date,
        kind: cart.kind,
        status: :pending_payment,
        subtotal: totals.subtotal,
        discount_total: totals.discount_total,
        total: totals.total
      })
    end)
    |> snapshot_items_multi(cart.items)
    |> Ecto.Multi.update(:cart, Cart.status_changeset(cart, :converted))
    |> Repo.transaction()
    |> case do
      {:ok, %{order: order}} -> {:ok, Repo.preload(order, items: :modifiers)}
      {:error, _step, reason, _changes} -> {:error, reason}
    end
  end

  @doc """
  Atomically re-reserves daily-limit stock for every line on an already-
  snapshotted `order` — the late-success resurrection path (Payments
  context, design-qa.md Q21): a charge confirms APPROVED after the
  12-minute sweep already expired the order and released its original
  hold. `{:error, :sold_out}` means a different order took the last
  portion in the interim; the caller (Payments) decides refund from
  there — this function never charges or refunds anything itself.
  """
  def reserve_holds_for_order(%Order{} = order) do
    order = Repo.preload(order, :items)
    lines = Enum.map(order.items, &{&1.menu_item_id, &1.qty})
    reserve_holds(lines, order.venue_id, order.business_date)
  end

  @doc """
  Display-only lookup for the Revive UI (design-qa.md Q26 "the POS says
  exactly which item sold out") — separate from `reserve_holds_for_order/1`
  itself so that function's `{:error, :sold_out}` contract (already relied
  on by the Q21 late-success path) never has to change shape just to carry
  a name. Best-effort: the first line whose daily limit has hit zero since
  the order was placed, or `nil` if the exact cause can't be pinned down
  (still a real sold-out, just not attributable to one line — the caller
  falls back to a generic message).
  """
  def first_sold_out_item_name(%Scope{} = scope, %Order{} = order) do
    order = Repo.preload(order, items: :menu_item)

    order.items
    |> Enum.find(fn item ->
      case Catalog.get_daily_limit(scope, item.menu_item, order.business_date) do
        nil -> false
        limit -> DailyItemLimit.remaining(limit) < item.qty
      end
    end)
    |> case do
      nil -> nil
      item -> item.name_snapshot
    end
  end

  # Atomic per line — a zero-row match means either "sold out" (a limit
  # row exists but had insufficient remaining) or "unlimited" (no limit
  # row at all, nothing to reserve); only the failure path pays for the
  # extra existence check to tell the two apart (design-qa.md Q1).
  defp reserve_holds(lines, venue_id, business_date) do
    Enum.reduce_while(lines, {:ok, :held}, fn {item_id, qty}, {:ok, _} ->
      case reserve_hold(item_id, qty, venue_id, business_date) do
        :ok -> {:cont, {:ok, :held}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp reserve_hold(item_id, qty, venue_id, business_date) do
    {count, _} =
      Repo.update_all(
        from(l in DailyItemLimit,
          where:
            l.item_id == ^item_id and l.venue_id == ^venue_id and l.date == ^business_date and
              l.limit_qty - l.sold_qty - l.reserved_qty >= ^qty
        ),
        inc: [reserved_qty: qty]
      )

    cond do
      count == 1 -> :ok
      limit_row_exists?(item_id, venue_id, business_date) -> {:error, :sold_out}
      true -> :ok
    end
  end

  defp limit_row_exists?(item_id, venue_id, business_date) do
    Repo.exists?(
      from(l in DailyItemLimit,
        where: l.item_id == ^item_id and l.venue_id == ^venue_id and l.date == ^business_date
      )
    )
  end

  # Atomic upsert-increment on (venue_id, business_date) — never a
  # read-then-write. First order of the day inserts fresh at 1; every
  # subsequent one increments the existing row (design-qa.md Q39).
  defp reserve_order_number(org_id, venue_id, business_date) do
    now = DateTime.utc_now(:second)

    entry = %{
      id: Ecto.UUID.generate(),
      org_id: org_id,
      venue_id: venue_id,
      business_date: business_date,
      next_number: 1,
      inserted_at: now,
      updated_at: now
    }

    {1, [%{next_number: number}]} =
      Repo.insert_all(OrderNumberCounter, [entry],
        on_conflict: [inc: [next_number: 1]],
        conflict_target: [:venue_id, :business_date],
        returning: [:next_number]
      )

    {:ok, number}
  end

  defp snapshot_items_multi(multi, cart_items) do
    cart_items
    |> Enum.with_index()
    |> Enum.reduce(multi, fn {cart_item, index}, multi ->
      multi
      |> Ecto.Multi.insert({:order_item, index}, fn %{order: order} ->
        order_item_changeset(order, cart_item)
      end)
      |> snapshot_modifiers_multi(index, cart_item.options)
    end)
  end

  defp snapshot_modifiers_multi(multi, item_index, options) do
    Enum.reduce(options, multi, fn option, multi ->
      Ecto.Multi.insert(multi, {:order_item_modifier, item_index, option.id}, fn changes ->
        order_item = Map.fetch!(changes, {:order_item, item_index})
        order_item_modifier_changeset(order_item, option)
      end)
    end)
  end

  defp order_item_changeset(order, cart_item) do
    %OrderItem{}
    |> Ecto.Changeset.change(%{
      org_id: order.org_id,
      order_id: order.id,
      menu_item_id: cart_item.menu_item.id,
      name_snapshot: cart_item.menu_item.name,
      unit_price_snapshot: cart_item.menu_item.price,
      qty: cart_item.qty,
      line_total: Totals.line_total(cart_item),
      notes: cart_item.notes
    })
  end

  defp order_item_modifier_changeset(order_item, option) do
    %OrderItemModifier{}
    |> Ecto.Changeset.change(%{
      org_id: order_item.org_id,
      order_item_id: order_item.id,
      option_id: option.id,
      name_snapshot: option.name,
      price_delta_snapshot: option.price_delta
    })
  end

  ## Discounts (build-plan.md Feature 15; design-qa.md Q36, architecture.md
  ## "Manager/cashier applied, permission-gated, always attributed") —
  ## pre-payment only. `Tabletap.Payments.charge_comp/4` builds on
  ## `apply_discount/4` for the 100%-discount comp path (Q30); everything
  ## else here is the ordinary partial-discount path either role can use.

  @doc """
  Attributes and applies a discount to a `pending_payment` order — either
  whole-order (`order_item_id: nil`) or against one line. Recomputes
  `discount_total`/`total` in the same transaction as the attribution row,
  so the two can never drift. `{:error, :not_pending_payment}` once the
  order has moved on (Q36 — a discount after payment is a refund, never
  a mutation here).
  """
  def apply_discount(
        %Scope{} = scope,
        %Order{status: :pending_payment} = order,
        attrs,
        %Membership{} = staff_membership
      ) do
    changeset =
      OrderDiscount.new_changeset(%{
        org_id: order.org_id,
        order_id: order.id,
        order_item_id: attrs[:order_item_id],
        staff_membership_id: staff_membership.id,
        amount: attrs[:amount],
        reason: attrs[:reason]
      })

    Ecto.Multi.new()
    |> Ecto.Multi.insert(:discount, changeset)
    |> Ecto.Multi.run(:order, fn _repo, _changes -> recompute_discount_total(scope, order) end)
    |> Repo.transaction()
    |> case do
      {:ok, %{order: order}} -> {:ok, order}
      {:error, :discount, changeset, _changes} -> {:error, changeset}
    end
  end

  def apply_discount(%Scope{}, %Order{}, _attrs, %Membership{}),
    do: {:error, :not_pending_payment}

  @doc "Reverses one discount row — same pre-payment guard as `apply_discount/4`."
  def remove_discount(%Scope{} = scope, %OrderDiscount{} = discount) do
    order = get_order(scope, discount.order_id)

    if order.status == :pending_payment do
      Ecto.Multi.new()
      |> Ecto.Multi.delete(:discount, discount)
      |> Ecto.Multi.run(:order, fn _repo, _changes -> recompute_discount_total(scope, order) end)
      |> Repo.transaction()
      |> case do
        {:ok, %{order: order}} -> {:ok, order}
      end
    else
      {:error, :not_pending_payment}
    end
  end

  @doc "Every discount attributed to `order`, oldest first — the POS payment screen's own itemized list."
  def list_discounts(%Scope{}, %Order{} = order) do
    Repo.all(from(d in OrderDiscount, where: d.order_id == ^order.id, order_by: d.inserted_at))
  end

  defp recompute_discount_total(%Scope{venue: venue}, order) do
    zero = Money.new!(venue.currency, 0)

    discount_total =
      Repo.all(from(d in OrderDiscount, where: d.order_id == ^order.id, select: d.amount))
      |> Enum.reduce(zero, &Money.add!(&2, &1))

    order |> Order.recompute_totals_changeset(discount_total) |> Repo.update()
  end

  ## Reading orders (the tracker, build-plan.md Feature 08)

  @terminal_statuses [:closed, :expired, :cancelled, :refunded]
  @kitchen_queue_statuses [:placed, :accepted, :preparing]

  @doc "A single order in the scope's venue, table/items/modifiers preloaded — `nil` for a cross-venue or unknown id (no Repo.get! on a guest-suppliable id)."
  def get_order(%Scope{venue: venue}, id) do
    Repo.one(
      from(o in Order,
        where: o.id == ^id and o.venue_id == ^venue.id,
        preload: [:table, items: [:menu_item, :modifiers]]
      )
    )
  end

  @doc """
  Today's order at this venue by its short display `number` — the
  cashier's pay-at-counter lookup (design-qa.md Q3: the customer's
  tracker shows just the number, not a full id). Scoped to *today's*
  business date since order numbers reset per business day (Q39) — the
  same number means a different order tomorrow. `nil` for an unknown
  number or one that already resolved to something other than
  `pending_payment`/`expired` (paid, cancelled — nothing left to verify).
  """
  def get_order_by_number(%Scope{venue: venue}, number) when is_integer(number) do
    business_date = Tenants.business_date(venue)

    Repo.one(
      from(o in Order,
        where:
          o.venue_id == ^venue.id and o.number == ^number and
            o.business_date == ^business_date and o.status in [:pending_payment, :expired],
        preload: [:table, items: [:menu_item, :modifiers]]
      )
    )
  end

  @doc """
  Today's order at this venue by number, any status — the cashier's
  refund lookup (build-plan.md Feature 15). Unlike `get_order_by_number/2`
  (scoped to the still-settling `pending_payment`/`expired` pair for the
  Q3 pay-at-counter flow), a refund is issued against an order that
  already *has* a payment — placed, in the kitchen, served, whatever its
  current status. Still scoped to today's business date: order numbers
  reset daily (Q39), so a stale number from yesterday must not resolve.
  """
  def get_any_order_by_number(%Scope{venue: venue}, number) when is_integer(number) do
    business_date = Tenants.business_date(venue)

    Repo.one(
      from(o in Order,
        where:
          o.venue_id == ^venue.id and o.number == ^number and o.business_date == ^business_date,
        preload: [:table, items: [:menu_item, :modifiers]]
      )
    )
  end

  @doc """
  The guest's most recent non-terminal order at this venue, if any —
  powers the "You have an active order →" banner on re-scan/reopen
  (design-qa.md Q13). Tenant-scoped as normal (no cross-venue lookup
  needed here: the guest is already on this venue's menu, so `scope` is
  already resolved).
  """
  def get_active_order_for_guest(%Scope{venue: venue}, guest_token) when is_binary(guest_token) do
    Repo.one(
      from(o in Order,
        where:
          o.guest_token == ^guest_token and o.venue_id == ^venue.id and
            o.status not in ^@terminal_statuses,
        order_by: [desc: o.inserted_at],
        limit: 1
      )
    )
  end

  def get_active_order_for_guest(%Scope{}, nil), do: nil

  @doc """
  A simple, honest ETA in minutes: this order's slowest line's
  `prep_minutes` (items are prepared in parallel by the kitchen, not
  summed) × the venue's current kitchen queue depth — build-plan.md
  Feature 08's own words, "static prep_minutes × queue depth for now."
  A real rolling-average ETA is a documented later refinement
  (architecture.md "Known Technical Risks"). Inflated by
  `venue.eta_inflation_factor` when Busy Mode's "Slow" is active (Q2).
  """
  def estimated_minutes(%Scope{venue: venue}, %Order{} = order) do
    base_minutes = expected_prep_minutes(order)
    queue_depth = max(count_kitchen_queue(venue), 1)
    inflation = venue.eta_inflation_factor || Decimal.new(1)

    (base_minutes * queue_depth)
    |> Decimal.new()
    |> Decimal.mult(inflation)
    |> Decimal.round(0, :up)
    |> Decimal.to_integer()
  end

  defp count_kitchen_queue(venue) do
    Repo.aggregate(
      from(o in Order, where: o.venue_id == ^venue.id and o.status in ^@kitchen_queue_statuses),
      :count
    )
  end

  ## Waiter assignment (build-plan.md Feature 10; architecture.md "Waiter
  ## Assignment Algorithm" — followed step for step)

  # A waiter's "open load" for scoring (architecture.md: "count of their
  # open orders (accepted/preparing/ready)").
  @open_load_statuses [:accepted, :preparing, :ready]
  # An order still on a waiter's plate when they go off shift — handed
  # to the claim board rather than silently orphaned (role-features.md
  # "Off-shift handoff").
  @handoff_statuses [:placed, :accepted, :preparing, :ready]

  @accept_window_seconds 90

  @doc """
  Runs the assignment algorithm for a freshly-`placed` order — called
  from `Workers.AssignWaiter` (never inline in the state machine; a
  crash mid-assignment must survive as a retryable job).

  `alive?` is the Presence liveness check, injectable so tests don't
  need a real Presence/Tracker process — production passes
  `TabletapWeb.Presence.alive?/2` (the default).

  Steps, in architecture.md's own order: pickup-mode venues skip
  assignment entirely (Q18), as does any `:counter`-kind order regardless
  of fulfillment mode (build-plan.md Feature 15 — a walk-in ticket has no
  table and no delivery step; the cashier hands it straight over); same-
  table stickiness (Q8); candidates = on-shift waiters (Staffing) ∩
  Presence-alive; solo-waiter shortcut auto-accepts (Q49); otherwise
  lowest open load with a longest-since-last-assignment tiebreak, then a
  90s escalation job. No candidates at all → straight to the claim board
  + manager alert.

  Idempotent: an order no longer `:placed`, or already assigned, is a
  no-op — Oban retries and duplicate jobs can never double-assign.
  """
  def assign_waiter(%Scope{venue: venue} = scope, %Order{} = order, alive? \\ nil) do
    alive? = alive? || (&TabletapWeb.Presence.alive?/2)

    cond do
      venue.fulfillment_mode == :pickup -> {:ok, :pickup_no_assignment}
      order.kind == :counter -> {:ok, :counter_no_assignment}
      order.status != :placed -> {:ok, :already_resolved}
      order.waiter_membership_id != nil -> {:ok, :already_assigned}
      true -> do_assign(scope, venue, order, alive?)
    end
  end

  defp do_assign(scope, venue, order, alive?) do
    case sticky_waiter_id(venue, order) do
      nil -> assign_by_load(scope, venue, order, alive?)
      membership_id -> assign_to(scope, order, membership_id, sticky: true)
    end
  end

  # Q8 — one waiter owns a table per sitting: any open order at the same
  # table already assigned to a waiter routes follow-ups to them.
  defp sticky_waiter_id(_venue, %Order{table_id: nil}), do: nil

  defp sticky_waiter_id(venue, order) do
    Repo.one(
      from(o in Order,
        where:
          o.venue_id == ^venue.id and o.table_id == ^order.table_id and o.id != ^order.id and
            o.status in ^@handoff_statuses and not is_nil(o.waiter_membership_id),
        order_by: [desc: o.inserted_at],
        limit: 1,
        select: o.waiter_membership_id
      )
    )
  end

  defp assign_by_load(scope, venue, order, alive?) do
    candidates =
      venue.id
      |> Tabletap.Staffing.list_on_shift_waiter_membership_ids()
      |> Enum.filter(&alive?.(venue.id, &1))

    case candidates do
      [] ->
        escalate_to_claim_board(scope, order)

      # Q49 — exactly one waiter on shift: auto-accept, no 90s window,
      # no claim-board hop; only the stalled-order watchdog alerts.
      [solo] ->
        {:ok, order} = assign_to(scope, order, solo, notify_only: true)
        OrderStateMachine.transition(scope, order, :accepted)

      many ->
        chosen = pick_lowest_load(venue, many)
        assign_to(scope, order, chosen)
    end
  end

  # Lowest open load; tiebreak = longest since last assignment
  # (round-robin fairness). A waiter with no orders at all sorts first
  # on both axes.
  defp pick_lowest_load(venue, candidate_ids) do
    stats =
      Repo.all(
        from(o in Order,
          where:
            o.venue_id == ^venue.id and o.waiter_membership_id in ^candidate_ids and
              o.status in ^@open_load_statuses,
          group_by: o.waiter_membership_id,
          select: {o.waiter_membership_id, count(o.id), max(o.inserted_at)}
        )
      )
      |> Map.new(fn {id, load, last} -> {id, {load, last}} end)

    Enum.min_by(candidate_ids, fn id ->
      {load, last_assigned} = Map.get(stats, id, {0, nil})
      # nil (never assigned) sorts before any DateTime — exactly the
      # fairness we want for a waiter who just clocked in.
      {load, last_assigned && DateTime.to_unix(last_assigned)}
    end)
  end

  defp assign_to(_scope, order, membership_id, opts \\ []) do
    {:ok, order} = order |> Order.assign_waiter_changeset(membership_id) |> Repo.update()

    :telemetry.execute([:tabletap, :order, :assigned], %{}, %{
      order_id: order.id,
      membership_id: membership_id,
      sticky: Keyword.get(opts, :sticky, false)
    })

    Phoenix.PubSub.broadcast(
      Tabletap.PubSub,
      "waiter:#{membership_id}",
      {:order_assigned, order.id}
    )

    # The solo-waiter shortcut accepts immediately — no window to enforce.
    unless Keyword.get(opts, :notify_only, false) do
      %{order_id: order.id, org_id: order.org_id, assigned_membership_id: membership_id}
      |> EscalateUnacceptedOrder.new(
        schedule_in: @accept_window_seconds,
        queue: :escalations
      )
      |> Oban.insert()
    end

    {:ok, order}
  end

  @doc """
  Unassigns `order` and puts it on the venue-wide claim board (the 90s
  escalation path, the no-waiters-on-shift path, and Q44's off-shift
  handoff all land here). The claim board is derived state — a `:placed`
  order with no waiter — not a separate table.
  """
  def escalate_to_claim_board(%Scope{venue: venue}, %Order{} = order) do
    {:ok, order} = order |> Order.assign_waiter_changeset(nil) |> Repo.update()

    :telemetry.execute([:tabletap, :order, :escalated], %{}, %{
      order_id: order.id,
      venue_id: venue.id
    })

    Phoenix.PubSub.broadcast(
      Tabletap.PubSub,
      "venue:#{venue.id}:claim_board",
      {:order_needs_claim, order.id}
    )

    {:ok, order}
  end

  @doc "The waiter accepts their assigned order — guarded to their own assignment, then `placed → accepted`."
  def accept_order(%Scope{membership: membership} = scope, %Order{} = order) do
    cond do
      order.waiter_membership_id != membership.id -> {:error, :not_yours}
      order.status != :placed -> {:error, :not_pending_accept}
      true -> OrderStateMachine.transition(scope, order, :accepted)
    end
  end

  @doc """
  First tap wins on the claim board: atomically takes an unassigned
  `:placed` order (`UPDATE ... WHERE waiter_membership_id IS NULL` — a
  zero-row match means someone else won the race, never a double-claim),
  then accepts it into the claimer's queue.
  """
  def claim_order(%Scope{venue: venue, membership: membership} = scope, order_id) do
    {count, _} =
      Repo.update_all(
        from(o in Order,
          where:
            o.id == ^order_id and o.venue_id == ^venue.id and o.status == :placed and
              is_nil(o.waiter_membership_id)
        ),
        set: [waiter_membership_id: membership.id]
      )

    case count do
      0 ->
        {:error, :already_claimed}

      1 ->
        order = get_order(scope, order_id)

        Phoenix.PubSub.broadcast(
          Tabletap.PubSub,
          "venue:#{venue.id}:claim_board",
          {:order_claimed, order_id}
        )

        OrderStateMachine.transition(scope, order, :accepted)
    end
  end

  @doc """
  Manager reassign (design-qa.md Q10): to a chosen waiter, or `nil` for
  the claim board. Never automatic — auto-reassigning food that may be
  physically in someone's hands creates double-delivery chaos.
  """
  def reassign_order(%Scope{} = scope, %Order{} = order, nil),
    do: escalate_to_claim_board(scope, order)

  def reassign_order(%Scope{} = scope, %Order{} = order, membership_id) do
    previous = order.waiter_membership_id
    {:ok, order} = assign_to(scope, order, membership_id, notify_only: order.status != :placed)

    if previous && previous != membership_id do
      Phoenix.PubSub.broadcast(
        Tabletap.PubSub,
        "waiter:#{previous}",
        {:order_unassigned, order.id}
      )
    end

    {:ok, order}
  end

  @doc """
  Waiter "Can't find customer" (design-qa.md Q9) — flags the order for
  the manager to resolve rather than letting it rot in `ready`. The
  status itself doesn't change; `flag` is the manager's work queue.
  """
  def mark_unserveable(%Scope{} = scope, %Order{} = order),
    do: flag_order(scope, order, :unserveable)

  @doc """
  Pickup no-show sweep (build-plan.md Feature 11, design-qa.md Q32) —
  flags a `ready` pickup-mode order that's sat uncollected past
  `pickup_timeout_minutes`. Same shape as `mark_unserveable/2`: status
  doesn't change, `flag` is the manager's work queue.
  """
  def mark_not_picked_up(%Scope{} = scope, %Order{} = order),
    do: flag_order(scope, order, :not_picked_up)

  defp flag_order(%Scope{venue: venue}, order, flag) do
    {:ok, order} = order |> Order.flag_changeset(flag) |> Repo.update()

    Phoenix.PubSub.broadcast(
      Tabletap.PubSub,
      "venue:#{venue.id}:orders",
      {:order_updated, order.id}
    )

    {:ok, order}
  end

  @doc """
  Design-qa.md Q27 "86'ing an item didn't warn about in-flight tickets":
  flags every open (`placed`/`accepted`/`preparing` — a `ready` order is
  already made, 86'ing the item now changes nothing for it)
  `Inventory`-triggered order containing `menu_item_id`,
  `:contains_86d_item`, so the manager's "Needs your attention" board
  (`list_flagged_orders/1`) surfaces them within seconds — the
  manager-alert half of Q27; the KDS-ticket-badge half waits on Feature
  14. Already-flagged orders are left alone, never clobbering an
  existing flag. Returns the count newly flagged.
  """
  def flag_open_orders_containing_item(%Scope{venue: venue} = scope, menu_item_id) do
    order_ids =
      Repo.all(
        from(o in Order,
          join: i in assoc(o, :items),
          where:
            o.venue_id == ^venue.id and o.status in ^@kitchen_queue_statuses and
              i.menu_item_id == ^menu_item_id and is_nil(o.flag),
          distinct: true,
          select: o.id
        )
      )

    orders = Repo.all(from(o in Order, where: o.id in ^order_ids))
    Enum.each(orders, &flag_order(scope, &1, :contains_86d_item))
    length(orders)
  end

  @doc """
  Q44's staff-lifecycle handoff, and the waiter clock-out flow: every
  open order on this membership's plate goes to the claim board. Returns
  the count released.
  """
  def release_orders_to_claim_board(%Scope{venue: venue} = scope, membership_id) do
    orders =
      Repo.all(
        from(o in Order,
          where:
            o.venue_id == ^venue.id and o.waiter_membership_id == ^membership_id and
              o.status in ^@handoff_statuses
        )
      )

    Enum.each(orders, &escalate_to_claim_board(scope, &1))
    length(orders)
  end

  ## Waiter queue reads (build-plan.md Feature 10)

  @doc "The waiter's own FIFO queue — oldest placed first, NEXT UP pinned by the UI."
  def list_waiter_queue(%Scope{venue: venue, membership: membership}) do
    Repo.all(
      from(o in Order,
        where:
          o.venue_id == ^venue.id and o.waiter_membership_id == ^membership.id and
            o.status in ^@handoff_statuses,
        order_by: [asc: o.placed_at],
        preload: [:table, items: [:menu_item, :modifiers]]
      )
    )
  end

  @doc "The venue-wide claim board: unassigned placed orders, oldest first."
  def list_claim_board(%Scope{venue: venue}) do
    Repo.all(
      from(o in Order,
        where: o.venue_id == ^venue.id and o.status == :placed and is_nil(o.waiter_membership_id),
        order_by: [asc: o.placed_at],
        preload: [:table, items: [:menu_item, :modifiers]]
      )
    )
  end

  @doc "Count of orders still in flight (placed/accepted/preparing/ready) — the stocktake 'warns when open orders exist' advisory (design-qa.md Q43); non-blocking, the caller just shows it."
  def count_open_orders(%Scope{venue: venue}) do
    Repo.aggregate(
      from(o in Order, where: o.venue_id == ^venue.id and o.status in ^@handoff_statuses),
      :count
    )
  end

  ## Kitchen board (build-plan.md Feature 14; design-qa.md Q25/Q27)

  @doc """
  Every ticket the KDS shows — the venue's in-flight orders
  (`placed`/`accepted`/`preparing`/`ready`), oldest placed first so the
  board reads top-to-bottom in cook order. `menu_item` is preloaded for
  `prep_minutes` (the per-ticket overdue threshold), never for live
  prices — tickets render snapshots only.
  """
  def list_kitchen_orders(%Scope{venue: venue}) do
    Repo.all(
      from(o in Order,
        where: o.venue_id == ^venue.id and o.status in ^@handoff_statuses,
        order_by: [asc: o.placed_at],
        preload: [:table, items: [:menu_item, :modifiers]]
      )
    )
  end

  @doc "One kitchen ticket by id — `nil` if it's cross-venue, unknown, or no longer in a kitchen status (the board's cue to drop it)."
  def get_kitchen_order(%Scope{venue: venue}, id) do
    Repo.one(
      from(o in Order,
        where: o.id == ^id and o.venue_id == ^venue.id and o.status in ^@handoff_statuses,
        preload: [:table, items: [:menu_item, :modifiers]]
      )
    )
  end

  @doc """
  The KDS "Start" tap. A `placed` ticket passes through `accepted` on
  its way to `preparing` — the machine has no `placed → preparing` edge,
  and starting to cook *is* acceptance (also the only accept path at a
  pickup-mode venue, where no waiter exists to accept). The waiter's own
  Accept button only shows on `placed`, so it simply disappears.

  `{:error, :stale}` when the tablet's ticket is behind reality (another
  device advanced it first) — the board reloads, never crashes.
  """
  def kitchen_start_order(%Scope{} = scope, %Order{status: :placed} = order) do
    with {:ok, accepted} <- OrderStateMachine.transition(scope, order, :accepted) do
      OrderStateMachine.transition(scope, accepted, :preparing)
    end
  end

  def kitchen_start_order(%Scope{} = scope, %Order{status: :accepted} = order),
    do: OrderStateMachine.transition(scope, order, :preparing)

  def kitchen_start_order(%Scope{}, %Order{}), do: {:error, :stale}

  @doc "The KDS \"Ready\" tap — `preparing → ready`; `{:error, :stale}` if the ticket moved on under this tablet."
  def kitchen_mark_ready(%Scope{} = scope, %Order{status: :preparing} = order),
    do: OrderStateMachine.transition(scope, order, :ready)

  def kitchen_mark_ready(%Scope{}, %Order{}), do: {:error, :stale}

  @doc """
  One-step-back undo (design-qa.md Q25): `ready → preparing` (retracts
  the waiter's pickup notification — the machine broadcasts that) or
  `preparing → accepted`. Anything else is `{:error, :stale}` — `served`
  is deliberately unreachable backwards (stock deducted, scan-confirmed;
  fixing a wrong serve is a manager refund flow).
  """
  def kitchen_undo(%Scope{} = scope, %Order{status: :ready} = order),
    do: OrderStateMachine.transition(scope, order, :preparing)

  def kitchen_undo(%Scope{} = scope, %Order{status: :preparing} = order),
    do: OrderStateMachine.transition(scope, order, :accepted)

  def kitchen_undo(%Scope{}, %Order{}), do: {:error, :stale}

  @doc """
  A ticket's overdue threshold in minutes — its slowest line's
  `prep_minutes` (parallel prep, same reasoning as `estimated_minutes/2`)
  with the same 10-minute default for items that never set one. Pure
  kitchen time: no queue-depth or Busy-Mode inflation — those manage the
  *customer's* expectation; the cook's clock starts honest.
  """
  def expected_prep_minutes(%Order{} = order) do
    order.items
    |> Enum.map(&(&1.menu_item && &1.menu_item.prep_minutes))
    |> Enum.reject(&is_nil/1)
    |> case do
      [] -> 10
      minutes -> Enum.max(minutes)
    end
  end

  ## Call waiter (build-plan.md Feature 10; design-qa.md Q46)

  @doc """
  Customer "call waiter" tap from the tracker. Only meaningful at a
  waiter-mode venue for a dine-in order — pickup venues never create a
  `waiter_calls` row (Q46: their tracker shows "Ask at the counter"
  instead of the button; this guard backs that UI rule server-side).
  """
  def call_waiter(%Scope{venue: %Venue{fulfillment_mode: :pickup}}, %Order{}),
    do: {:error, :pickup_venue}

  def call_waiter(%Scope{}, %Order{table_id: nil}), do: {:error, :no_table}

  def call_waiter(%Scope{org: org, venue: venue}, %Order{} = order) do
    result =
      %{
        org_id: org.id,
        venue_id: venue.id,
        table_id: order.table_id,
        order_id: order.id
      }
      |> WaiterCall.new_changeset()
      |> Repo.insert()

    with {:ok, call} <- result do
      :telemetry.execute([:tabletap, :waiter, :called], %{}, %{
        table_id: order.table_id,
        order_id: order.id,
        membership_id: order.waiter_membership_id
      })

      topic =
        if order.waiter_membership_id,
          do: "waiter:#{order.waiter_membership_id}",
          else: "venue:#{venue.id}:claim_board"

      Phoenix.PubSub.broadcast(Tabletap.PubSub, topic, {:waiter_called, order.id})
      {:ok, call}
    end
  end

  ## Serve confirmation (build-plan.md Feature 11; design-qa.md Q18/Q19)

  @doc """
  Waiter/staff scan-confirm: the scanned QR value must match this
  order's serve token — the table's printed `qr_token` for a dine-in
  order, or the customer's own tracker-page QR (their `guest_token`) for
  a takeaway order or any order at a pickup-mode venue, neither of which
  has a table to scan (Q18). `order.table` must already be preloaded
  when `order.table_id` is set — every real caller reaches this via
  `list_waiter_queue/1` or `get_order/2`, which both preload it.

  A mismatch is `{:error, :token_mismatch}`, not a crash — wrong table,
  wrong customer, or a stale/reused QR are all ordinary user error, not
  a bug (contrast `OrderStateMachine`'s illegal-transition raise).
  """
  def confirm_served_by_scan(%Scope{} = scope, %Order{status: :ready} = order, scanned_value) do
    if serve_token(scope, order) == scanned_value do
      OrderStateMachine.transition(scope, order, :served)
    else
      {:error, :token_mismatch}
    end
  end

  def confirm_served_by_scan(%Scope{}, %Order{}, _scanned_value), do: {:error, :not_ready}

  @doc """
  The value a scan must match to serve `order` — public so the order
  tracker can decide whether to render the "show this to staff" QR
  without duplicating this branching (it must stay in sync with what
  `confirm_served_by_scan/3` actually checks against): the customer's
  own `guest_token` for a pickup-mode venue or a table-less (takeaway)
  order, otherwise the order's table's `qr_token`.
  """
  def serve_token(%Scope{venue: %Venue{fulfillment_mode: :pickup}}, %Order{} = order),
    do: order.guest_token

  def serve_token(%Scope{}, %Order{table_id: nil} = order), do: order.guest_token
  def serve_token(%Scope{}, %Order{table: %Tabletap.Tenants.Table{} = table}), do: table.qr_token

  @doc """
  Manager-only manual serve confirm (design-qa.md Q19) — the scan
  fallback for a damaged table QR. Bypasses the token check entirely,
  but is always attributed (`scope.role`) and telemetry-counted
  separately from a normal scan-confirm, so habitual bypassing shows up
  in the employee work report (Feature 18) rather than hiding inside the
  ordinary serve numbers. Route-level `ScopeHooks.require_manager`
  restricts who can ever reach this, same as every other manager-only
  action in this codebase (code-standards.md — authorization lives at
  the route, not re-checked per context function).

  Also the shared "settle" step for the flag-resolution functions below
  (`mark_collected/2`, `close_as_wasted/2`) — clearing any existing flag
  in the same write is exactly what resolving it means.
  """
  def confirm_served_manually(%Scope{} = scope, %Order{status: :ready} = order) do
    with {:ok, served} <- OrderStateMachine.transition(scope, order, :served) do
      :telemetry.execute([:tabletap, :order, :serve_override], %{}, %{
        order_id: served.id,
        actor_role: scope.role
      })

      clear_flag_if_set(served)
    end
  end

  def confirm_served_manually(%Scope{}, %Order{}), do: {:error, :not_ready}

  defp clear_flag_if_set(%Order{flag: nil} = order), do: {:ok, order}
  defp clear_flag_if_set(order), do: order |> Order.clear_flag_changeset() |> Repo.update()

  @doc "Ready orders needing a serve confirm, oldest first — excludes already-flagged ones (they show up in `list_flagged_orders/1` instead)."
  def list_ready_orders(%Scope{venue: venue}) do
    Repo.all(
      from(o in Order,
        where: o.venue_id == ^venue.id and o.status == :ready and is_nil(o.flag),
        order_by: [asc: o.ready_at],
        preload: [:table, items: [:menu_item, :modifiers]]
      )
    )
  end

  @doc "Orders flagged for manager attention (`:unserveable`/`:not_picked_up`), oldest first."
  def list_flagged_orders(%Scope{venue: venue}) do
    Repo.all(
      from(o in Order,
        where: o.venue_id == ^venue.id and not is_nil(o.flag),
        order_by: [asc: o.flagged_at],
        preload: [:table, items: [:menu_item, :modifiers]]
      )
    )
  end

  ## Flag resolution (build-plan.md Feature 11; design-qa.md Q9/Q10/Q32) —
  ## manager only (route-gated, same as confirm_served_manually/2 above).

  @doc """
  Refunds a flagged `ready` order in full and settles it as `:refunded`
  — the resolution shared by both `:unserveable` (Q9/Q10 "refund or
  convert to takeaway") and `:not_picked_up` (Q32 "refund / mark
  collected / close + wastage"). A comp order (`payments.provider:
  :comp`, Q30) never charged anything, so there's no money to move —
  only the order settles.
  """
  def resolve_flag_refund(%Scope{} = scope, %Order{} = order, staff_user_id) do
    case Payments.get_latest_payment_for_order(scope, order.id) do
      nil -> {:error, :no_payment}
      %{provider: :comp} -> settle_refunded(scope, order)
      payment -> refund_and_settle(scope, order, payment, staff_user_id)
    end
  end

  defp refund_and_settle(scope, order, payment, staff_user_id) do
    with {:ok, _refund} <-
           Payments.refund(scope, payment, payment.amount, refund_reason(order), staff_user_id) do
      settle_refunded(scope, order)
    end
  end

  defp settle_refunded(scope, order) do
    with {:ok, order} <- OrderStateMachine.transition(scope, order, :refunded) do
      order |> Order.clear_flag_changeset() |> Repo.update()
    end
  end

  defp refund_reason(%Order{flag: :unserveable}),
    do: "Customer could not be found (design-qa.md Q9)"

  defp refund_reason(%Order{flag: :not_picked_up}),
    do: "Order not collected (design-qa.md Q32)"

  defp refund_reason(%Order{flag: :contains_86d_item}),
    do: "Item 86'd, kitchen couldn't fulfill the order (design-qa.md Q27)"

  @doc """
  Unserveable resolution (Q9/Q10): the customer will collect this
  themselves — converts to a takeaway order (drops the waiter
  assignment, clears the flag) rather than delivering it.
  """
  def convert_to_takeaway(%Scope{} = scope, %Order{flag: :unserveable} = order) do
    order
    |> Order.convert_to_takeaway_changeset()
    |> Repo.update()
    |> broadcast_order_updated(scope)
  end

  @doc "Pickup no-show resolution (Q32): the customer did collect it — staff just never scanned. Same effect as a normal serve confirm."
  def mark_collected(%Scope{} = scope, %Order{flag: :not_picked_up} = order),
    do: confirm_served_manually(scope, order)

  @doc "Q27 resolution: the kitchen confirms it can still make the remaining portions despite the 86 — clears the flag, no status change, the order carries on normally."
  def mark_still_makeable(%Scope{} = scope, %Order{flag: :contains_86d_item} = order) do
    order |> Order.clear_flag_changeset() |> Repo.update() |> broadcast_order_updated(scope)
  end

  @doc """
  Pickup no-show resolution (Q32): the food was made but never
  collected. `served` first (stock still deducts — it was cooked, same
  comp-vs-void discipline `Q30` already established for made-but-unpaid
  food) then straight to `closed`, no refund. A real wastage-ledger
  attribution is Feature 13's job; this only settles the order honestly
  in the meantime.
  """
  def close_as_wasted(%Scope{} = scope, %Order{flag: :not_picked_up} = order) do
    with {:ok, served} <- confirm_served_manually(scope, order) do
      OrderStateMachine.transition(scope, served, :closed)
    end
  end

  defp broadcast_order_updated({:ok, order} = result, %Scope{venue: venue}) do
    Phoenix.PubSub.broadcast(
      Tabletap.PubSub,
      "venue:#{venue.id}:orders",
      {:order_updated, order.id}
    )

    result
  end

  defp broadcast_order_updated(error, %Scope{}), do: error

  ## Customer accounts & cross-venue history (build-plan.md Feature 16;
  ## architecture.md "Customer data is NOT tenant-owned" — a customer's
  ## own orders span every org they've ever visited, so neither of these
  ## takes a `%Scope{}` (there is no single org/venue to scope to). Same
  ## cross-tenant shape as `Workers.SweepAbandonedCarts`: loop
  ## `Tenants.list_org_ids/0`, `Repo.put_org_id/1` per org, then a normal
  ## tenant-scoped query — never `skip_org_id: true` (`Ordering` isn't on
  ## that exception list, code-standards.md "Tenancy Rules").

  @history_statuses Order.statuses() -- [:pending_payment, :cancelled, :expired]

  @doc """
  Stamps `customer_user_id` on every order (across every org) matching
  `guest_token` — the write side of design-qa.md's "Save your history"
  flow: `guest_token` persists in a 30-day cookie across venues, so one
  signup can retroactively claim every order that guest_token ever
  placed, at any venue, in one pass. Idempotent (a second call is a
  harmless no-op) — safe to call from `UserLive.Confirmation` on every
  visit to a valid magic-link, not just the first.
  """
  def link_guest_orders_to_customer(%Accounts.User{} = user, guest_token)
      when is_binary(guest_token) do
    total =
      Tenants.list_org_ids()
      |> Enum.reduce(0, fn org_id, acc ->
        Repo.put_org_id(org_id)

        {count, _} =
          Repo.update_all(
            from(o in Order, where: o.guest_token == ^guest_token),
            set: [customer_user_id: user.id]
          )

        acc + count
      end)

    {:ok, total}
  end

  @doc """
  Every order across every org attributed to `user` — the `/me/history`
  read. Excludes orders that never really happened
  (`pending_payment`/`cancelled`/`expired` — nothing was made, nothing
  was paid); a `refunded` order still shows (food was made, money moved).
  Newest first; `venue` preloaded for cross-venue display.
  """
  def list_orders_for_customer(%Accounts.User{} = user) do
    Tenants.list_org_ids()
    |> Enum.flat_map(fn org_id ->
      Repo.put_org_id(org_id)

      Repo.all(
        from(o in Order,
          where: o.customer_user_id == ^user.id and o.status in ^@history_statuses,
          order_by: [desc: o.placed_at],
          preload: :venue
        )
      )
    end)
    |> Enum.sort_by(& &1.placed_at, {:desc, DateTime})
  end
end
