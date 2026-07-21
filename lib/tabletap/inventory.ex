defmodule Tabletap.Inventory do
  @moduledoc """
  Ingredients, recipes, and the stock ledger (architecture.md
  "inventory/"; build-plan.md Features 12/13). A menu item with no
  recipe lines deducts nothing on serve — the correct behavior for an
  un-reciped item (most venues before they set this up at all), not a
  bug to work around.

  `Ordering` and `Catalog` call this context's public functions only,
  never `Repo.get(Ingredient, ...)` directly (architecture.md "Context
  rule"); this context calls back into `Catalog.set_availability/3`
  (auto-86, Q11) and `Ordering.flag_open_orders_containing_item/2`
  (Q27) the same way — public functions, never their Repo queries.

  Plan gating (role-features.md: ingredients/stock ops/alerts/stocktake
  are Growth+) lives at the route level (`TabletapWeb.PlanHooks
  :inventory`, `UserAuth.require_inventory_feature/2`, build-plan.md
  Feature 19) — this context itself stays plan-agnostic, same as every
  other context (`Ordering`, `Catalog`, ...) never checks `org.plan`
  on its own.
  """

  import Ecto.Query, warn: false

  alias Tabletap.Accounts.Scope
  alias Tabletap.Catalog
  alias Tabletap.Catalog.MenuItem

  alias Tabletap.Inventory.{
    Ingredient,
    RecipeLine,
    StockMovement,
    StocktakeLine,
    StocktakeSession
  }

  alias Tabletap.Notifications.Workers.SendPush
  alias Tabletap.Ordering
  alias Tabletap.Ordering.Order
  alias Tabletap.Repo

  ## Ingredients (build-plan.md Feature 12)

  @doc "Every non-archived ingredient at the scope's venue, ordered by name."
  def list_ingredients(%Scope{venue: venue}) do
    Repo.all(
      from(i in Ingredient,
        where: i.venue_id == ^venue.id and is_nil(i.archived_at),
        order_by: i.name
      )
    )
  end

  def get_ingredient(%Scope{venue: venue}, id) do
    Repo.one(from(i in Ingredient, where: i.id == ^id and i.venue_id == ^venue.id))
  end

  @doc "A fresh ingredient, always starting at `stock_qty: 0` — see `Ingredient`'s moduledoc for why that's not user-settable."
  def create_ingredient(%Scope{org: org, venue: venue}, attrs) do
    %Ingredient{org_id: org.id, venue_id: venue.id}
    |> Ingredient.creation_changeset(attrs)
    |> Repo.insert()
  end

  def update_ingredient(%Scope{}, %Ingredient{} = ingredient, attrs) do
    ingredient |> Ingredient.update_changeset(attrs) |> Repo.update()
  end

  @doc "Archives an ingredient (design-qa.md Q41) — hidden from the recipe editor/restock pickers, intact in every recipe_line/stock_movement FK and report."
  def archive_ingredient(%Scope{}, %Ingredient{} = ingredient) do
    ingredient |> Ingredient.archive_changeset() |> Repo.update()
  end

  ## Recipe lines (build-plan.md Feature 12's recipe editor)

  @doc "A menu item's bill of materials, ingredient preloaded, alphabetical — what `Manager.MenuLive`'s item modal renders."
  def list_recipe_lines(%Scope{}, %Tabletap.Catalog.MenuItem{} = item) do
    Repo.all(
      from(r in RecipeLine,
        where: r.menu_item_id == ^item.id,
        join: i in assoc(r, :ingredient),
        order_by: i.name,
        preload: [ingredient: i]
      )
    )
  end

  @doc "Adds one ingredient to an item's recipe. Attaching the same ingredient twice returns `{:error, changeset}` via the unique constraint (design-qa.md — same discipline as `Catalog.attach_group_to_item/3`)."
  def add_recipe_line(
        %Scope{org: org},
        %Tabletap.Catalog.MenuItem{} = item,
        %Ingredient{} = ingredient,
        qty_per_serving
      ) do
    %RecipeLine{}
    |> RecipeLine.creation_changeset(%{
      org_id: org.id,
      menu_item_id: item.id,
      ingredient_id: ingredient.id,
      qty_per_serving: qty_per_serving
    })
    |> Repo.insert()
  end

  def update_recipe_line_qty(%Scope{}, %RecipeLine{} = recipe_line, qty_per_serving) do
    recipe_line |> RecipeLine.qty_changeset(qty_per_serving) |> Repo.update()
  end

  def remove_recipe_line(%Scope{}, %RecipeLine{} = recipe_line) do
    Repo.delete(recipe_line)
    :ok
  end

  ## Stock operations (build-plan.md Feature 13) — restock, manual
  ## adjustment, wastage, all append-only `stock_movements` rows.

  @doc """
  Restock entry: increments stock, writes a `:restock` movement
  recording the price actually paid, and refreshes
  `ingredients.cost_per_unit` to that price — the next restock report
  values suggested reorders at the latest real cost, not a stale one.
  """
  def restock(
        %Scope{org: org, venue: venue} = scope,
        %Ingredient{} = ingredient,
        qty,
        unit_cost,
        staff_user_id
      ) do
    Ecto.Multi.new()
    |> Ecto.Multi.run(:stock, fn _repo, _changes -> inc_stock(ingredient.id, qty) end)
    |> Ecto.Multi.insert(
      :movement,
      movement_changeset(org, venue, ingredient, qty, :restock,
        unit_cost: unit_cost,
        staff_user_id: staff_user_id
      )
    )
    |> Ecto.Multi.update(:ingredient, Ecto.Changeset.change(ingredient, cost_per_unit: unit_cost))
    |> Repo.transaction()
    |> after_movement(scope, ingredient.id)
  end

  @doc """
  A manual stock correction — up or down, always reasoned and attributed
  (code-standards.md "manual order edits always record who did it" —
  same discipline for stock). Negative resulting stock is allowed
  (design-qa.md Q14 "service never blocks on bookkeeping") — it shows up
  in `list_negative_stock/1` until reconciled, never rejected here.
  """
  def adjust_stock(
        %Scope{org: org, venue: venue} = scope,
        %Ingredient{} = ingredient,
        qty_delta,
        note,
        staff_user_id
      ) do
    Ecto.Multi.new()
    |> Ecto.Multi.run(:stock, fn _repo, _changes -> inc_stock(ingredient.id, qty_delta) end)
    |> Ecto.Multi.insert(
      :movement,
      movement_changeset(org, venue, ingredient, qty_delta, :adjustment,
        note: note,
        staff_user_id: staff_user_id
      )
    )
    |> Repo.transaction()
    |> after_movement(scope, ingredient.id)
  end

  @doc "Wastage log — spoilage, drops, prep mistakes. `qty` is the positive amount wasted; stored as a negative movement, reason required."
  def log_wastage(
        %Scope{org: org, venue: venue} = scope,
        %Ingredient{} = ingredient,
        qty,
        note,
        staff_user_id
      ) do
    Ecto.Multi.new()
    |> Ecto.Multi.run(:stock, fn _repo, _changes ->
      inc_stock(ingredient.id, Decimal.negate(qty))
    end)
    |> Ecto.Multi.insert(
      :movement,
      movement_changeset(org, venue, ingredient, Decimal.negate(qty), :wastage,
        note: note,
        staff_user_id: staff_user_id
      )
    )
    |> Repo.transaction()
    |> after_movement(scope, ingredient.id)
  end

  defp inc_stock(ingredient_id, qty_delta) do
    Repo.update_all(from(i in Ingredient, where: i.id == ^ingredient_id),
      inc: [stock_qty: qty_delta]
    )

    {:ok, :updated}
  end

  defp movement_changeset(org, venue, ingredient, qty_delta, reason, opts) do
    StockMovement.movement_changeset(%{
      org_id: org.id,
      venue_id: venue.id,
      ingredient_id: ingredient.id,
      qty_delta: qty_delta,
      reason: reason,
      unit_cost: Keyword.get(opts, :unit_cost),
      note: Keyword.get(opts, :note),
      staff_user_id: Keyword.get(opts, :staff_user_id)
    })
  end

  defp after_movement(
         {:ok, %{movement: movement}},
         %Scope{org: org, venue: venue} = scope,
         ingredient_id
       ) do
    broadcast_if_low_stock(org.id, venue.id, ingredient_id)
    # A restock/positive adjustment can only make things more fulfillable
    # — only a net decrease is ever worth an auto-86 check.
    if Decimal.negative?(movement.qty_delta), do: maybe_auto_86(scope, [ingredient_id])
    {:ok, movement}
  end

  defp after_movement({:error, _step, changeset, _changes}, %Scope{}, _ingredient_id) do
    {:error, changeset}
  end

  ## Low-stock alerts (build-plan.md Feature 13)

  @doc "Whether `ingredient` is at or below its own threshold — `false` for an ingredient with no threshold set (there's nothing to alert against)."
  def low_stock?(%Ingredient{min_threshold: nil}), do: false

  def low_stock?(%Ingredient{stock_qty: qty, min_threshold: threshold}) do
    Decimal.compare(qty, threshold) != :gt
  end

  @doc "Every non-archived, thresholded ingredient currently at or below its threshold — the manager's live low-stock board."
  def list_low_stock(%Scope{venue: venue}) do
    Repo.all(
      from(i in Ingredient,
        where:
          i.venue_id == ^venue.id and is_nil(i.archived_at) and not is_nil(i.min_threshold) and
            i.stock_qty <= i.min_threshold,
        order_by: i.name
      )
    )
  end

  @doc "Every non-archived ingredient with negative computed stock (design-qa.md Q14) — flagged until a restock or stocktake reconciles it back to zero or above."
  def list_negative_stock(%Scope{venue: venue}) do
    Repo.all(
      from(i in Ingredient,
        where: i.venue_id == ^venue.id and is_nil(i.archived_at) and i.stock_qty < 0,
        order_by: i.name
      )
    )
  end

  @doc """
  Ingredients needing restock (`list_low_stock/1`, always thresholded
  and currently at or below it), each with a suggested reorder quantity
  — `threshold × 2 − current` (build-plan.md Feature 13) — most urgent
  (biggest deficit) first. Powers the restock report page, its CSV
  export, and the printable purchase-order sheet, so all three are
  always looking at the same numbers.
  """
  def restock_report(%Scope{} = scope) do
    scope
    |> list_low_stock()
    |> Enum.map(fn ingredient ->
      %{
        ingredient: ingredient,
        current: ingredient.stock_qty,
        threshold: ingredient.min_threshold,
        suggested: suggested_reorder(ingredient)
      }
    end)
    |> Enum.sort_by(& &1.current, Decimal)
  end

  defp suggested_reorder(%Ingredient{stock_qty: current, min_threshold: threshold}) do
    threshold |> Decimal.mult(2) |> Decimal.sub(current)
  end

  # `venue:<id>:inventory` — the low-stock ping the build-plan verify
  # step describes ("dropping cheese below threshold pings the manager
  # dashboard live"). This is the live PubSub half any manager-facing
  # inventory view subscribes to, same pattern `venue:<id>:orders`/
  # `venue:<id>:claim_board` already use elsewhere; the Web Push half
  # (build-plan.md Feature 20) is the `SendPush` enqueue right below.
  defp broadcast_if_low_stock(org_id, venue_id, ingredient_id) do
    ingredient = Repo.get(Ingredient, ingredient_id)

    if low_stock?(ingredient) do
      Phoenix.PubSub.broadcast(
        Tabletap.PubSub,
        "venue:#{venue_id}:inventory",
        {:low_stock, ingredient}
      )

      :telemetry.execute([:tabletap, :inventory, :low_stock], %{}, %{
        ingredient_id: ingredient.id,
        venue_id: venue_id
      })

      %{
        "type" => "low_stock",
        "org_id" => org_id,
        "venue_id" => venue_id,
        "title" => "Low stock",
        "body" => "#{ingredient.name} is running low",
        "url" => "/inventory"
      }
      |> SendPush.new()
      |> Oban.insert()
    end
  end

  @doc """
  Writes one `stock_movements` `:sale` row per (order line × recipe
  line) and decrements the matching `ingredients.stock_qty` — called
  from `OrderStateMachine.transition/3` inside the same transaction as
  the `served` status write (architecture.md "On served:
  Inventory.deduct_for_order/2 writes stock_movements per recipe line").
  `order.items` must already be preloaded (the state machine always
  preloads before calling this) — this function preloads each item's
  `:modifiers` itself, since that's only ever needed on this one path.

  Each order line contributes its base recipe (`qty_per_serving × qty`)
  plus every chosen modifier's own `ingredient_qty_delta` (build-plan.md
  Feature 12) — "extra cheese" adds on top of the recipe, "no onions"
  subtracts from it, both `× qty`. A line and its modifiers can net to
  zero for a given ingredient (a removal exactly offsetting the recipe's
  own amount) — that ingredient simply doesn't appear in the movements
  written, not a zero-quantity row.

  Idempotency isn't this function's job — the state machine only ever
  calls it on a genuine `_ -> served` transition, and `served` has no
  transition back to itself (`OrderStateMachine.legal?/2`), so it can
  never run twice for the same order.

  Returns `{:ok, :no_recipe}` when nothing in the order — base recipes
  or modifier deltas alike — resolves to any net deduction (every venue,
  before Feature 12 ships, or any order with no reciped items chosen) —
  a correct no-op, not an error.
  """
  def deduct_for_order(%Scope{org: org, venue: venue} = scope, %Order{} = order) do
    order.items
    |> Repo.preload(:modifiers)
    |> Enum.flat_map(&line_deductions(org.id, &1))
    |> merge_by_ingredient()
    |> case do
      [] ->
        {:ok, :no_recipe}

      deductions ->
        movements = write_deductions(scope, order.id, deductions)

        :telemetry.execute([:tabletap, :inventory, :stock_deducted], %{}, %{
          order_id: order.id,
          venue_id: venue.id,
          movement_count: length(movements)
        })

        {:ok, movements}
    end
  end

  defp line_deductions(org_id, order_item) do
    recipe_deltas =
      org_id
      |> recipe_lines_for(order_item.menu_item_id)
      |> Enum.map(fn line ->
        {line.ingredient_id, Decimal.mult(line.qty_per_serving, Decimal.new(order_item.qty))}
      end)

    modifier_deltas =
      Enum.flat_map(order_item.modifiers, &modifier_deduction(org_id, &1, order_item.qty))

    recipe_deltas ++ modifier_deltas
  end

  defp recipe_lines_for(org_id, menu_item_id) do
    Repo.all(
      from(r in RecipeLine, where: r.org_id == ^org_id and r.menu_item_id == ^menu_item_id)
    )
  end

  defp modifier_deduction(org_id, order_item_modifier, qty) do
    case option_ingredient_delta(org_id, order_item_modifier.option_id) do
      {ingredient_id, delta} when not is_nil(ingredient_id) ->
        [{ingredient_id, Decimal.mult(delta, Decimal.new(qty))}]

      _no_stock_effect ->
        []
    end
  end

  defp option_ingredient_delta(org_id, option_id) do
    Repo.one(
      from(o in Tabletap.Catalog.ModifierOption,
        where: o.id == ^option_id and o.org_id == ^org_id,
        select: {o.ingredient_id, o.ingredient_qty_delta}
      )
    )
  end

  # Two lines on the same order (or the same ingredient in two different
  # items' recipes/modifiers) collapse into one movement row per
  # ingredient. A net-zero total (a removal modifier exactly offsetting
  # its own recipe amount) is dropped entirely — not a zero-quantity
  # audit row.
  defp merge_by_ingredient(deductions) do
    deductions
    |> Enum.group_by(fn {ingredient_id, _qty} -> ingredient_id end, fn {_id, qty} -> qty end)
    |> Enum.map(fn {ingredient_id, qtys} ->
      {ingredient_id, Enum.reduce(qtys, &Decimal.add/2)}
    end)
    |> Enum.reject(fn {_id, qty} -> Decimal.equal?(qty, 0) end)
  end

  defp write_deductions(%Scope{org: org, venue: venue} = scope, order_id, deductions) do
    Repo.transaction(fn ->
      Enum.map(deductions, fn {ingredient_id, qty} ->
        deducted = Decimal.negate(qty)

        Repo.update_all(
          from(i in Ingredient, where: i.id == ^ingredient_id),
          inc: [stock_qty: deducted]
        )

        %{
          org_id: org.id,
          venue_id: venue.id,
          ingredient_id: ingredient_id,
          order_id: order_id,
          qty_delta: deducted
        }
        |> StockMovement.deduction_changeset()
        |> Repo.insert!()
      end)
    end)
    |> case do
      {:ok, movements} ->
        # "Low-stock detection on every deduction" (build-plan.md Feature
        # 13) — the sale path, not just restock/adjust/wastage.
        ingredient_ids = Enum.map(movements, & &1.ingredient_id)
        Enum.each(ingredient_ids, &broadcast_if_low_stock(org.id, venue.id, &1))
        maybe_auto_86(scope, ingredient_ids)
        movements
    end
  end

  ## Auto-86 (build-plan.md Feature 13, design-qa.md Q11/Q27)

  # Only ever called with ingredients whose stock just *decreased*
  # (sale, wastage, a negative adjustment) — a restock or a positive
  # adjustment can only make an item more fulfillable, never less, so
  # there's nothing to check on those paths.
  defp maybe_auto_86(%Scope{org: org} = scope, ingredient_ids) do
    ingredient_ids
    |> Enum.uniq()
    |> Enum.each(fn ingredient_id ->
      org.id
      |> menu_items_using_ingredient(ingredient_id)
      |> Enum.each(&auto_86_if_unfulfillable(scope, &1))
    end)
  end

  defp menu_items_using_ingredient(org_id, ingredient_id) do
    Repo.all(
      from(m in MenuItem,
        join: r in RecipeLine,
        on: r.menu_item_id == m.id,
        where:
          r.org_id == ^org_id and r.ingredient_id == ^ingredient_id and is_nil(m.archived_at) and
            m.active == true and m.available_today == true,
        distinct: true
      )
    )
  end

  defp auto_86_if_unfulfillable(%Scope{org: org, venue: venue} = scope, %MenuItem{} = item) do
    unless fulfillable?(org.id, item.id) do
      {:ok, _item} = Catalog.set_availability(scope, item, false)

      :telemetry.execute([:tabletap, :inventory, :auto_86], %{}, %{
        menu_item_id: item.id,
        venue_id: venue.id
      })

      Ordering.flag_open_orders_containing_item(scope, item.id)
    end
  end

  # Fulfillable = every ingredient in the item's *base* recipe has
  # enough stock for one more serving. Modifier deltas aren't checked
  # here — a specific customer's "extra cheese" pick is a per-order
  # question checkout/the kitchen already sees at serve time, not a
  # menu-wide availability one; auto-86 answers "can the dish as
  # photographed still be made," the same question the daily-limit
  # sold-out badge already answers for portion counts.
  defp fulfillable?(org_id, menu_item_id) do
    org_id
    |> recipe_lines_for(menu_item_id)
    |> Enum.all?(fn line ->
      ingredient = Repo.get(Ingredient, line.ingredient_id)
      Decimal.compare(ingredient.stock_qty, line.qty_per_serving) != :lt
    end)
  end

  ## Stocktake (build-plan.md Feature 13, design-qa.md Q14/Q43)

  @doc "The venue's open stocktake session, if one exists — the UI only ever lets one run at a time (starting a new one while another is open would double-count movements against overlapping snapshots)."
  def get_open_stocktake(%Scope{venue: venue}) do
    Repo.one(from(s in StocktakeSession, where: s.venue_id == ^venue.id and s.status == :open))
  end

  @doc """
  Opens a new stocktake session and snapshots every non-archived,
  active ingredient's current `stock_qty`/`cost_per_unit` into its own
  `stocktake_lines` row (design-qa.md Q43 "session snapshots theoretical
  quantities at start" — so sales during the count never move the
  number the count gets compared against). Returns `{:error,
  :already_open}` rather than starting a second concurrent session.
  """
  def start_stocktake(%Scope{org: org, venue: venue, user: user} = scope) do
    if get_open_stocktake(scope) do
      {:error, :already_open}
    else
      Ecto.Multi.new()
      |> Ecto.Multi.insert(
        :session,
        StocktakeSession.new_changeset(%{
          org_id: org.id,
          venue_id: venue.id,
          started_by_user_id: user && user.id
        })
      )
      |> Ecto.Multi.run(:lines, fn _repo, %{session: session} ->
        {:ok, snapshot_lines(scope, session)}
      end)
      |> Repo.transaction()
      |> case do
        {:ok, %{session: session}} -> {:ok, session}
        {:error, _step, changeset, _changes} -> {:error, changeset}
      end
    end
  end

  defp snapshot_lines(%Scope{org: org} = scope, session) do
    scope
    |> list_ingredients()
    |> Enum.map(fn ingredient ->
      %{
        org_id: org.id,
        session_id: session.id,
        ingredient_id: ingredient.id,
        theoretical_qty_snapshot: ingredient.stock_qty,
        unit_cost_snapshot: ingredient.cost_per_unit
      }
      |> StocktakeLine.snapshot_changeset()
      |> Repo.insert!()
    end)
  end

  @doc "A session's lines, ingredient preloaded, alphabetical — what the count-entry screen renders."
  def list_stocktake_lines(%Scope{}, %StocktakeSession{} = session) do
    Repo.all(
      from(l in StocktakeLine,
        where: l.session_id == ^session.id,
        join: i in assoc(l, :ingredient),
        order_by: i.name,
        preload: [ingredient: i]
      )
    )
  end

  def record_count(%Scope{}, %StocktakeLine{} = line, counted_qty) do
    line |> StocktakeLine.count_changeset(counted_qty) |> Repo.update()
  end

  @doc """
  Closes a session: every line with a count entered gets a reconciling
  `:adjustment` movement bringing `stock_qty` to exactly what was
  counted — `counted − current actual stock`, **not** `counted −
  snapshot` (sales that happened during the count are real and already
  correctly reflected in current stock; only the gap between counted-
  reality and the ledger's current belief needs reconciling). Lines
  never counted are left untouched — nothing to reconcile.

  Returns `{:ok, session, variance_report}` — the report values each
  counted line as `counted − theoretical_qty_snapshot` (the diagnostic
  number design-qa.md Q43 defines, deliberately not adjusted for
  interim sales — recommend counting at close to keep that window
  short), valued at the snapshotted cost.
  """
  def close_stocktake(%Scope{} = scope, %StocktakeSession{} = session) do
    lines = list_stocktake_lines(scope, session)
    counted_lines = Enum.filter(lines, &(&1.counted_qty != nil))

    Ecto.Multi.new()
    |> Ecto.Multi.update(:session, StocktakeSession.close_changeset(session))
    |> reconcile_multi(scope, counted_lines)
    |> Repo.transaction()
    |> case do
      {:ok, %{session: session}} -> {:ok, session, variance_report(counted_lines)}
      {:error, _step, changeset, _changes} -> {:error, changeset}
    end
  end

  defp reconcile_multi(multi, scope, counted_lines) do
    Enum.reduce(counted_lines, multi, fn line, multi ->
      Ecto.Multi.run(multi, {:reconcile, line.id}, fn _repo, _changes ->
        reconcile_line(scope, line)
      end)
    end)
  end

  defp reconcile_line(scope, line) do
    ingredient = Repo.get!(Ingredient, line.ingredient_id)
    variance_from_actual = Decimal.sub(line.counted_qty, ingredient.stock_qty)

    if Decimal.equal?(variance_from_actual, 0) do
      {:ok, :no_change}
    else
      adjust_stock(
        scope,
        ingredient,
        variance_from_actual,
        "Stocktake reconciliation",
        scope.user && scope.user.id
      )
    end
  end

  defp variance_report(counted_lines) do
    Enum.map(counted_lines, fn line ->
      variance = Decimal.sub(line.counted_qty, line.theoretical_qty_snapshot)

      %{
        ingredient: line.ingredient,
        theoretical: line.theoretical_qty_snapshot,
        counted: line.counted_qty,
        variance: variance,
        value: variance_value(variance, line.unit_cost_snapshot)
      }
    end)
  end

  defp variance_value(_variance, nil), do: nil
  defp variance_value(variance, %Money{} = unit_cost), do: Money.mult!(unit_cost, variance)
end
