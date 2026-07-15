defmodule Tabletap.InventoryTest do
  @moduledoc """
  `Tabletap.Inventory` — build-plan.md Feature 12: ingredient/recipe
  CRUD and deduction (base recipe + modifier deltas).
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

  # Ingredient creation never accepts stock_qty (every unit of stock must
  # come from a ledger row) — tests seed it directly to stay independent
  # of the stock-op functions.
  defp stocked_ingredient(scope, attrs) do
    ingredient = ingredient_fixture(scope, attrs)
    {qty, _} = attrs |> Map.get("stock_qty", "0") |> Decimal.parse()

    Repo.update_all(
      from(i in Ingredient, where: i.id == ^ingredient.id),
      set: [stock_qty: qty]
    )

    Repo.get!(Ingredient, ingredient.id)
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
end
