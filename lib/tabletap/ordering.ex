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

  alias Tabletap.Accounts.Scope
  alias Tabletap.Catalog
  alias Tabletap.Catalog.{DailyItemLimit, MenuItem}
  alias Tabletap.Ordering.{Cart, CartItem, CartItemOption, Order, OrderItem, OrderItemModifier}
  alias Tabletap.Ordering.{OrderNumberCounter, OrderStateMachine, Totals, WaiterCall}
  alias Tabletap.Repo
  alias Tabletap.Tenants
  alias Tabletap.Tenants.Venue

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

  @doc "Dine-in vs takeaway (build-plan.md Feature 07)."
  def set_kind(%Scope{}, %Cart{} = cart, kind) when kind in [:dine_in, :takeaway] do
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

  defp do_checkout(%Scope{org: org, venue: venue}, cart) do
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

  ## Reading orders (the tracker, build-plan.md Feature 08)

  @terminal_statuses [:closed, :expired, :cancelled, :refunded]
  @kitchen_queue_statuses [:placed, :accepted, :preparing]

  @doc "A single order in the scope's venue, items/modifiers preloaded — `nil` for a cross-venue or unknown id (no Repo.get! on a guest-suppliable id)."
  def get_order(%Scope{venue: venue}, id) do
    Repo.one(
      from(o in Order,
        where: o.id == ^id and o.venue_id == ^venue.id,
        preload: [items: [:menu_item, :modifiers]]
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
    base_minutes =
      order.items
      |> Enum.map(&(&1.menu_item && &1.menu_item.prep_minutes))
      |> Enum.reject(&is_nil/1)
      |> case do
        [] -> 10
        minutes -> Enum.max(minutes)
      end

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
  assignment entirely (Q18); same-table stickiness (Q8); candidates =
  on-shift waiters (Staffing) ∩ Presence-alive; solo-waiter shortcut
  auto-accepts (Q49); otherwise lowest open load with a
  longest-since-last-assignment tiebreak, then a 90s escalation job.
  No candidates at all → straight to the claim board + manager alert.

  Idempotent: an order no longer `:placed`, or already assigned, is a
  no-op — Oban retries and duplicate jobs can never double-assign.
  """
  def assign_waiter(%Scope{venue: venue} = scope, %Order{} = order, alive? \\ nil) do
    alive? = alive? || (&TabletapWeb.Presence.alive?/2)

    cond do
      venue.fulfillment_mode == :pickup -> {:ok, :pickup_no_assignment}
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
      |> Tabletap.Ordering.Workers.EscalateUnacceptedOrder.new(
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
  def mark_unserveable(%Scope{venue: venue}, %Order{} = order) do
    {:ok, order} = order |> Order.flag_changeset(:unserveable) |> Repo.update()
    Phoenix.PubSub.broadcast(Tabletap.PubSub, "venue:#{venue.id}:orders", :order_updated)
    {:ok, order}
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
end
