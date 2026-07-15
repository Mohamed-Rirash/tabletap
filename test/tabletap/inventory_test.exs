defmodule Tabletap.InventoryTest do
  @moduledoc """
  `Tabletap.Inventory` — build-plan.md Features 12/13: ingredient/recipe
  CRUD, deduction (base recipe + modifier deltas), restock/adjust/
  wastage, low-stock alerts, auto-86 + Q27 open-ticket flagging, and
  stocktake (snapshot-at-start, variance report vs. snapshot, reconciling
  adjustment vs. current actual — design-qa.md Q43).
  """
  use Tabletap.DataCase, async: true

  import Ecto.Query
  import Tabletap.TenantsFixtures

  alias Tabletap.Accounts.Scope
  alias Tabletap.Catalog
  alias Tabletap.Inventory
  alias Tabletap.Inventory.{Ingredient, StockMovement}
  alias Tabletap.Ordering
  alias Tabletap.Ordering.{Cart, Order, OrderStateMachine}
  alias Tabletap.Repo

  setup do
    %{org: org, venue: venue} = org_fixture()
    Repo.put_org_id(org.id)
    scope = %Scope{org: org, venue: venue}

    {:ok, category} = Catalog.create_category(scope, %{"name" => "Food"})

    {:ok, item} =
      Catalog.create_item(scope, category, %{
        "name" => "Burger",
        "price" => Money.new!(:USD, "8.00")
      })

    %{scope: scope, org: org, venue: venue, item: item}
  end

  defp ingredient_fixture(scope, attrs \\ %{}) do
    {:ok, ingredient} =
      Inventory.create_ingredient(
        scope,
        Enum.into(attrs, %{"name" => "Bun", "unit" => "piece"})
      )

    ingredient
  end

  defp stocked_ingredient(scope, attrs) do
    ingredient = ingredient_fixture(scope, attrs)
    {qty, _} = attrs |> Map.get("stock_qty", "0") |> Decimal.parse()
    {:ok, movement} = Inventory.restock(scope, ingredient, qty, Money.new!(:USD, "1.00"), nil)
    Repo.get!(Ingredient, movement.ingredient_id)
  end

  defp ready_order(scope, item, opts \\ []) do
    qty = Keyword.get(opts, :qty, 1)
    option_ids = Keyword.get(opts, :option_ids, [])
    token = Cart.generate_guest_token()
    {:ok, cart} = Ordering.add_to_cart(scope, token, nil, item, option_ids, qty, nil)
    {:ok, order} = Ordering.checkout(scope, cart)
    {:ok, order} = OrderStateMachine.transition(scope, order, :placed)
    {:ok, order} = OrderStateMachine.transition(scope, order, :accepted)
    {:ok, order} = OrderStateMachine.transition(scope, order, :preparing)
    {:ok, order} = OrderStateMachine.transition(scope, order, :ready)
    Ordering.get_order(scope, order.id)
  end

  defp kitchen_order(scope, item, opts \\ []) do
    qty = Keyword.get(opts, :qty, 1)
    token = Cart.generate_guest_token()
    {:ok, cart} = Ordering.add_to_cart(scope, token, nil, item, [], qty, nil)
    {:ok, order} = Ordering.checkout(scope, cart)
    {:ok, order} = OrderStateMachine.transition(scope, order, :placed)
    order
  end

  describe "ingredients CRUD (Feature 12)" do
    test "creates always at stock_qty zero, regardless of attrs", %{scope: scope} do
      {:ok, ingredient} =
        Inventory.create_ingredient(scope, %{
          "name" => "Cheese",
          "unit" => "g",
          "stock_qty" => "500"
        })

      assert Decimal.equal?(ingredient.stock_qty, 0)
    end

    test "update changes name/unit/threshold but never stock_qty", %{scope: scope} do
      ingredient = ingredient_fixture(scope, %{"name" => "Cheese", "unit" => "g"})

      {:ok, updated} =
        Inventory.update_ingredient(scope, ingredient, %{
          "name" => "Cheddar",
          "stock_qty" => "9999"
        })

      assert updated.name == "Cheddar"
      assert Decimal.equal?(updated.stock_qty, 0)
    end

    test "archive hides it from list_ingredients but leaves the row intact", %{scope: scope} do
      ingredient = ingredient_fixture(scope)
      assert {:ok, archived} = Inventory.archive_ingredient(scope, ingredient)
      assert archived.archived_at
      refute ingredient.id in Enum.map(Inventory.list_ingredients(scope), & &1.id)
      assert Repo.get(Ingredient, ingredient.id)
    end
  end

  describe "recipe lines (Feature 12)" do
    test "add/list/remove a recipe line", %{scope: scope, item: item} do
      bun = ingredient_fixture(scope, %{"name" => "Bun", "unit" => "piece"})

      assert {:ok, line} = Inventory.add_recipe_line(scope, item, bun, Decimal.new(1))
      assert [loaded] = Inventory.list_recipe_lines(scope, item)
      assert loaded.ingredient.id == bun.id

      assert :ok = Inventory.remove_recipe_line(scope, line)
      assert Inventory.list_recipe_lines(scope, item) == []
    end

    test "attaching the same ingredient twice is rejected", %{scope: scope, item: item} do
      bun = ingredient_fixture(scope)
      {:ok, _} = Inventory.add_recipe_line(scope, item, bun, Decimal.new(1))
      assert {:error, _changeset} = Inventory.add_recipe_line(scope, item, bun, Decimal.new(2))
    end
  end

  describe "deduct_for_order/2 — base recipe + modifier deltas" do
    test "writes one movement per ingredient and decrements stock_qty", %{
      scope: scope,
      item: item
    } do
      bun = stocked_ingredient(scope, %{"name" => "Bun", "unit" => "piece", "stock_qty" => "50"})

      cheese =
        stocked_ingredient(scope, %{"name" => "Cheese", "unit" => "g", "stock_qty" => "5000"})

      {:ok, _} = Inventory.add_recipe_line(scope, item, bun, Decimal.new(1))
      {:ok, _} = Inventory.add_recipe_line(scope, item, cheese, Decimal.new(150))

      order = ready_order(scope, item, qty: 2)
      {:ok, _} = OrderStateMachine.transition(scope, order, :served)
      movements = Repo.all(from(m in StockMovement, where: m.order_id == ^order.id))

      assert length(movements) == 2
      assert Repo.get!(Ingredient, bun.id).stock_qty |> Decimal.equal?(48)
      assert Repo.get!(Ingredient, cheese.id).stock_qty |> Decimal.equal?(4700)
    end

    test "a modifier's ingredient delta adds on top of the base recipe", %{
      scope: scope,
      item: item
    } do
      cheese =
        stocked_ingredient(scope, %{"name" => "Cheese", "unit" => "g", "stock_qty" => "1000"})

      {:ok, _} = Inventory.add_recipe_line(scope, item, cheese, Decimal.new(20))

      {:ok, group} =
        Catalog.create_modifier_group(scope, %{
          "name" => "Extras",
          "min_selections" => 0,
          "max_selections" => 1
        })

      {:ok, option} =
        Catalog.create_modifier_option(scope, group, %{
          "name" => "Extra cheese",
          "price_delta" => Money.new!(:USD, "1.00"),
          "ingredient_id" => cheese.id,
          "ingredient_qty_delta" => "20"
        })

      {:ok, _} = Catalog.attach_group_to_item(scope, item, group)

      order = ready_order(scope, item, option_ids: [option.id])
      {:ok, _} = OrderStateMachine.transition(scope, order, :served)

      # base 20g + modifier delta 20g = 40g total for one serving.
      assert Repo.get!(Ingredient, cheese.id).stock_qty |> Decimal.equal?(960)
    end

    test "a removal modifier that exactly offsets the base recipe writes no movement for that ingredient",
         %{
           scope: scope,
           item: item
         } do
      onion = stocked_ingredient(scope, %{"name" => "Onion", "unit" => "g", "stock_qty" => "500"})
      {:ok, _} = Inventory.add_recipe_line(scope, item, onion, Decimal.new(15))

      {:ok, group} =
        Catalog.create_modifier_group(scope, %{
          "name" => "Remove",
          "min_selections" => 0,
          "max_selections" => 1
        })

      {:ok, option} =
        Catalog.create_modifier_option(scope, group, %{
          "name" => "No onions",
          "price_delta" => Money.new!(:USD, "0.00"),
          "ingredient_id" => onion.id,
          "ingredient_qty_delta" => "-15"
        })

      {:ok, _} = Catalog.attach_group_to_item(scope, item, group)

      order = ready_order(scope, item, option_ids: [option.id])
      {:ok, _} = OrderStateMachine.transition(scope, order, :served)

      assert Repo.get!(Ingredient, onion.id).stock_qty |> Decimal.equal?(500)

      sale_movements =
        Repo.aggregate(
          from(m in StockMovement, where: m.ingredient_id == ^onion.id and m.reason == :sale),
          :count
        )

      assert sale_movements == 0
    end

    test "no recipe at all is a correct no-op", %{scope: scope, item: item} do
      order = ready_order(scope, item)
      assert {:ok, served} = OrderStateMachine.transition(scope, order, :served)
      assert served.status == :served
    end
  end

  describe "stock operations (Feature 13)" do
    test "restock increments stock, writes a movement, and refreshes cost_per_unit", %{
      scope: scope
    } do
      ingredient = ingredient_fixture(scope, %{"name" => "Flour", "unit" => "g"})

      assert {:ok, movement} =
               Inventory.restock(
                 scope,
                 ingredient,
                 Decimal.new(5000),
                 Money.new!(:USD, "0.50"),
                 nil
               )

      assert movement.reason == :restock
      assert Decimal.equal?(movement.qty_delta, 5000)
      reloaded = Repo.get!(Ingredient, ingredient.id)
      assert Decimal.equal?(reloaded.stock_qty, 5000)
      assert Money.equal?(reloaded.cost_per_unit, Money.new!(:USD, "0.50"))
    end

    test "adjust_stock allows negative resulting stock (Q14) and requires a note", %{scope: scope} do
      ingredient =
        stocked_ingredient(scope, %{"name" => "Milk", "unit" => "ml", "stock_qty" => "100"})

      assert {:ok, _} =
               Inventory.adjust_stock(
                 scope,
                 ingredient,
                 Decimal.new(-150),
                 "count correction",
                 nil
               )

      assert Repo.get!(Ingredient, ingredient.id).stock_qty |> Decimal.equal?(-50)

      assert {:error, changeset} =
               Inventory.adjust_stock(scope, ingredient, Decimal.new(10), nil, nil)

      assert %{note: ["can't be blank"]} = errors_on(changeset)
    end

    test "log_wastage stores a negative movement and requires a reason", %{scope: scope} do
      ingredient =
        stocked_ingredient(scope, %{"name" => "Tomato", "unit" => "g", "stock_qty" => "1000"})

      assert {:ok, movement} =
               Inventory.log_wastage(scope, ingredient, Decimal.new(200), "dropped", nil)

      assert Decimal.equal?(movement.qty_delta, -200)
      assert movement.reason == :wastage
      assert Repo.get!(Ingredient, ingredient.id).stock_qty |> Decimal.equal?(800)
    end
  end

  describe "low-stock / negative-stock (Feature 13)" do
    test "low_stock?/1 and list_low_stock/1", %{scope: scope} do
      low =
        stocked_ingredient(scope, %{
          "name" => "Salt",
          "unit" => "g",
          "stock_qty" => "50",
          "min_threshold" => "100"
        })

      fine =
        stocked_ingredient(scope, %{
          "name" => "Pepper",
          "unit" => "g",
          "stock_qty" => "500",
          "min_threshold" => "100"
        })

      assert Inventory.low_stock?(Repo.get!(Ingredient, low.id))
      refute Inventory.low_stock?(Repo.get!(Ingredient, fine.id))
      assert [%{id: id}] = Inventory.list_low_stock(scope)
      assert id == low.id
    end

    test "an ingredient with no threshold is never low stock", %{scope: scope} do
      ingredient = ingredient_fixture(scope, %{"name" => "Water", "unit" => "ml"})
      refute Inventory.low_stock?(ingredient)
    end

    test "list_negative_stock/1 surfaces ingredients driven below zero", %{scope: scope} do
      ingredient =
        stocked_ingredient(scope, %{"name" => "Butter", "unit" => "g", "stock_qty" => "50"})

      {:ok, _} = Inventory.adjust_stock(scope, ingredient, Decimal.new(-100), "correction", nil)

      assert [%{id: id}] = Inventory.list_negative_stock(scope)
      assert id == ingredient.id
    end

    test "restock_report suggests threshold × 2 − current, most urgent first", %{scope: scope} do
      _low =
        stocked_ingredient(scope, %{
          "name" => "Rice",
          "unit" => "g",
          "stock_qty" => "100",
          "min_threshold" => "500"
        })

      report = Inventory.restock_report(scope)

      assert [
               %{
                 ingredient: %{name: "Rice"},
                 current: current,
                 threshold: threshold,
                 suggested: suggested
               }
             ] = report

      assert Decimal.equal?(current, 100)
      assert Decimal.equal?(threshold, 500)
      # 500 * 2 - 100 = 900
      assert Decimal.equal?(suggested, 900)
    end
  end

  describe "auto-86 + Q27 open-ticket flagging (design-qa.md Q11/Q27)" do
    test "serving the last of an ingredient auto-86s an item that needs it", %{
      scope: scope,
      item: item
    } do
      cheese =
        stocked_ingredient(scope, %{"name" => "Cheese", "unit" => "g", "stock_qty" => "150"})

      {:ok, _} = Inventory.add_recipe_line(scope, item, cheese, Decimal.new(150))

      order = ready_order(scope, item)
      {:ok, _} = OrderStateMachine.transition(scope, order, :served)

      reloaded_item = Catalog.get_item(scope, item.id)
      refute reloaded_item.available_today
    end

    test "auto-86 flags open kitchen orders containing the item, not ready/served ones", %{
      scope: scope,
      item: item
    } do
      cheese =
        stocked_ingredient(scope, %{"name" => "Cheese", "unit" => "g", "stock_qty" => "150"})

      {:ok, _} = Inventory.add_recipe_line(scope, item, cheese, Decimal.new(150))

      in_flight = kitchen_order(scope, item)
      trigger = ready_order(scope, item)

      {:ok, _} = OrderStateMachine.transition(scope, trigger, :served)

      assert Repo.get!(Order, in_flight.id).flag == :contains_86d_item
      assert Repo.get!(Order, trigger.id).flag == nil
    end

    test "doesn't clobber an order that's already flagged for something else", %{
      scope: scope,
      item: item
    } do
      cheese =
        stocked_ingredient(scope, %{"name" => "Cheese", "unit" => "g", "stock_qty" => "150"})

      {:ok, _} = Inventory.add_recipe_line(scope, item, cheese, Decimal.new(150))

      in_flight = kitchen_order(scope, item)
      {:ok, _} = Ordering.mark_unserveable(scope, in_flight)

      trigger = ready_order(scope, item)
      {:ok, _} = OrderStateMachine.transition(scope, trigger, :served)

      assert Repo.get!(Order, in_flight.id).flag == :unserveable
    end

    test "mark_still_makeable/2 clears the flag with no status change", %{
      scope: scope,
      item: item
    } do
      cheese =
        stocked_ingredient(scope, %{"name" => "Cheese", "unit" => "g", "stock_qty" => "150"})

      {:ok, _} = Inventory.add_recipe_line(scope, item, cheese, Decimal.new(150))

      order = kitchen_order(scope, item)
      trigger = ready_order(scope, item)
      {:ok, _} = OrderStateMachine.transition(scope, trigger, :served)

      flagged = Repo.get!(Order, order.id)
      assert flagged.flag == :contains_86d_item

      assert {:ok, cleared} = Ordering.mark_still_makeable(scope, flagged)
      assert cleared.flag == nil
      assert cleared.status == :placed
    end

    test "a restock never triggers auto-86 (only decreases matter)", %{scope: scope, item: item} do
      cheese =
        stocked_ingredient(scope, %{"name" => "Cheese", "unit" => "g", "stock_qty" => "10"})

      {:ok, _} = Inventory.add_recipe_line(scope, item, cheese, Decimal.new(150))

      # Already unfulfillable at creation, but restock/adjust should only
      # ever *check* on a decrease — a positive restock must not 86 it.
      {:ok, _} = Inventory.restock(scope, cheese, Decimal.new(500), Money.new!(:USD, "1.00"), nil)

      assert Catalog.get_item(scope, item.id).available_today
    end
  end

  describe "stocktake (design-qa.md Q14/Q43)" do
    test "start_stocktake snapshots current stock/cost per ingredient", %{scope: scope} do
      ingredient =
        stocked_ingredient(scope, %{"name" => "Flour", "unit" => "g", "stock_qty" => "1000"})

      assert {:ok, session} = Inventory.start_stocktake(scope)
      assert [line] = Inventory.list_stocktake_lines(scope, session)
      assert line.ingredient.id == ingredient.id
      assert Decimal.equal?(line.theoretical_qty_snapshot, 1000)
      assert line.counted_qty == nil
    end

    test "only one open session at a time", %{scope: scope} do
      {:ok, _session} = Inventory.start_stocktake(scope)
      assert {:error, :already_open} = Inventory.start_stocktake(scope)
    end

    test "close reconciles against current actual stock, not the stale snapshot — sales during the count are honored",
         %{
           scope: scope,
           item: item
         } do
      ingredient =
        stocked_ingredient(scope, %{"name" => "Flour", "unit" => "g", "stock_qty" => "1000"})

      {:ok, _} = Inventory.add_recipe_line(scope, item, ingredient, Decimal.new(300))

      {:ok, session} = Inventory.start_stocktake(scope)

      # A sale happens mid-session — current actual drops to 700, but the
      # snapshot stays frozen at 1000.
      order = ready_order(scope, item)
      {:ok, _} = OrderStateMachine.transition(scope, order, :served)
      assert Repo.get!(Ingredient, ingredient.id).stock_qty |> Decimal.equal?(700)

      [line] = Inventory.list_stocktake_lines(scope, session)
      {:ok, _} = Inventory.record_count(scope, line, Decimal.new(650))

      assert {:ok, _closed, [variance_row]} = Inventory.close_stocktake(scope, session)

      # Report variance is counted vs. the *snapshot* (650 - 1000 = -350),
      # deliberately not sales-adjusted (design-qa.md Q43).
      assert Decimal.equal?(variance_row.variance, -350)

      # But the reconciling ledger movement brings stock to exactly what
      # was counted (650), reconciling against the 700 actual, not 1000.
      assert Repo.get!(Ingredient, ingredient.id).stock_qty |> Decimal.equal?(650)

      movement =
        Repo.one(
          from(m in StockMovement,
            where: m.ingredient_id == ^ingredient.id and m.reason == :adjustment,
            order_by: [desc: m.inserted_at],
            limit: 1
          )
        )

      assert Decimal.equal?(movement.qty_delta, -50)
    end

    test "an uncounted line is left untouched at close", %{scope: scope} do
      ingredient =
        stocked_ingredient(scope, %{"name" => "Sugar", "unit" => "g", "stock_qty" => "500"})

      {:ok, session} = Inventory.start_stocktake(scope)

      assert {:ok, _closed, []} = Inventory.close_stocktake(scope, session)
      assert Repo.get!(Ingredient, ingredient.id).stock_qty |> Decimal.equal?(500)
    end

    test "values the variance report at the snapshotted cost", %{scope: scope} do
      ingredient = ingredient_fixture(scope, %{"name" => "Coffee", "unit" => "g"})

      {:ok, _} =
        Inventory.restock(scope, ingredient, Decimal.new(1000), Money.new!(:USD, "0.02"), nil)

      {:ok, session} = Inventory.start_stocktake(scope)
      [line] = Inventory.list_stocktake_lines(scope, session)
      {:ok, _} = Inventory.record_count(scope, line, Decimal.new(900))

      assert {:ok, _closed, [row]} = Inventory.close_stocktake(scope, session)
      assert Decimal.equal?(row.variance, -100)
      assert Money.equal?(row.value, Money.new!(:USD, "-2.00"))
    end
  end
end
