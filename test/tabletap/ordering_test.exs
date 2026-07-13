defmodule Tabletap.OrderingTest do
  use Tabletap.DataCase, async: true

  import Ecto.Query

  alias Tabletap.Accounts.Scope
  alias Tabletap.{Catalog, Ordering, Repo, Tenants}
  alias Tabletap.Ordering.{Cart, OrderStateMachine}

  import Tabletap.TenantsFixtures

  setup do
    %{org: org, venue: venue} = org_fixture()
    Repo.put_org_id(org.id)
    %{scope: %Scope{org: org, venue: venue}, org: org, venue: venue}
  end

  defp category_fixture(scope, attrs \\ %{}) do
    {:ok, category} = Catalog.create_category(scope, Enum.into(attrs, %{"name" => "Drinks"}))
    category
  end

  defp item_fixture(scope, attrs \\ %{}) do
    category = category_fixture(scope)

    {:ok, item} =
      Catalog.create_item(
        scope,
        category,
        Enum.into(attrs, %{"name" => "Burger", "price" => Money.new!(:USD, "5.00")})
      )

    item
  end

  defp group_fixture(scope, attrs) do
    {:ok, group} =
      Catalog.create_modifier_group(
        scope,
        Enum.into(attrs, %{"name" => "Extras", "min_selections" => 0, "max_selections" => 3})
      )

    group
  end

  defp option_fixture(scope, group, attrs \\ %{}) do
    {:ok, option} =
      Catalog.create_modifier_option(
        scope,
        group,
        Enum.into(attrs, %{"name" => "Extra cheese", "price_delta" => Money.new!(:USD, "1.00")})
      )

    option
  end

  defp attach_fixture(scope, item, group) do
    {:ok, _} = Catalog.attach_group_to_item(scope, item, group)
    :ok
  end

  defp guest_token, do: Cart.generate_guest_token()

  describe "get_active_cart/2" do
    test "nil when the guest has no cart yet", %{scope: scope} do
      assert Ordering.get_active_cart(scope, guest_token()) == nil
    end

    test "nil for a nil guest_token (not-yet-minted guest)", %{scope: scope} do
      assert Ordering.get_active_cart(scope, nil) == nil
    end
  end

  describe "add_to_cart/7" do
    test "creates a cart and a line on first add", %{scope: scope} do
      item = item_fixture(scope)
      token = guest_token()

      assert {:ok, cart} = Ordering.add_to_cart(scope, token, nil, item, [], 2, "no napkins")

      assert cart.guest_token == token
      assert cart.status == :active
      assert cart.kind == :dine_in
      assert [line] = cart.items
      assert line.menu_item.id == item.id
      assert line.qty == 2
      assert line.notes == "no napkins"
      assert line.options == []
    end

    test "a second add for the same guest+venue reuses the same cart", %{scope: scope} do
      item = item_fixture(scope)
      token = guest_token()

      {:ok, _} = Ordering.add_to_cart(scope, token, nil, item, [], 1, nil)
      {:ok, cart} = Ordering.add_to_cart(scope, token, nil, item, [], 1, nil)

      assert length(cart.items) == 2
      assert [%{id: cart_id}] = Repo.all(Cart)
      assert cart.id == cart_id
    end

    test "two different guests at the same venue get independent carts", %{scope: scope} do
      item = item_fixture(scope)
      token_a = guest_token()
      token_b = guest_token()

      {:ok, cart_a} = Ordering.add_to_cart(scope, token_a, nil, item, [], 1, nil)
      {:ok, cart_b} = Ordering.add_to_cart(scope, token_b, nil, item, [], 1, nil)

      assert cart_a.id != cart_b.id
      assert length(cart_a.items) == 1
      assert length(cart_b.items) == 1
    end

    test "attaches selected options that are validly within the item's groups", %{scope: scope} do
      item = item_fixture(scope)
      group = group_fixture(scope, %{"min_selections" => 1, "max_selections" => 1})
      option = option_fixture(scope, group)
      :ok = attach_fixture(scope, item, group)

      assert {:ok, cart} =
               Ordering.add_to_cart(scope, guest_token(), nil, item, [option.id], 1, nil)

      assert [line] = cart.items
      assert [selected] = line.options
      assert selected.id == option.id
    end

    test "rejects an unattached/foreign option id", %{scope: scope} do
      item = item_fixture(scope)
      other_group = group_fixture(scope, %{"min_selections" => 0, "max_selections" => 1})
      foreign_option = option_fixture(scope, other_group)
      # foreign_option's group was never attached to item.

      assert {:error, :options_changed} =
               Ordering.add_to_cart(scope, guest_token(), nil, item, [foreign_option.id], 1, nil)

      assert Ordering.get_active_cart(scope, guest_token()) == nil
    end

    test "rejects a selection short of a required group's minimum", %{scope: scope} do
      item = item_fixture(scope)

      group =
        group_fixture(scope, %{"min_selections" => 1, "max_selections" => 1, "required" => true})

      _option = option_fixture(scope, group)
      :ok = attach_fixture(scope, item, group)

      assert {:error, :options_changed} =
               Ordering.add_to_cart(scope, guest_token(), nil, item, [], 1, nil)
    end

    test "rejects an inactive item", %{scope: scope} do
      item = item_fixture(scope)
      {:ok, item} = Catalog.update_item(scope, item, %{"active" => false})

      assert {:error, :item_unavailable} =
               Ordering.add_to_cart(scope, guest_token(), nil, item, [], 1, nil)
    end

    test "rejects an item that's sold out today", %{scope: scope} do
      item = item_fixture(scope)
      {:ok, _} = Catalog.set_daily_limit(scope, item, 1)
      # Sell out the one available unit directly against the limit row.
      limit = Catalog.get_daily_limit(scope, item)

      Repo.update_all(from(l in Tabletap.Catalog.DailyItemLimit, where: l.id == ^limit.id),
        set: [sold_qty: 1]
      )

      assert {:error, :item_unavailable} =
               Ordering.add_to_cart(scope, guest_token(), nil, item, [], 1, nil)
    end

    test "rejects a qty over the 20-unit cap", %{scope: scope} do
      item = item_fixture(scope)

      assert {:error, changeset} =
               Ordering.add_to_cart(scope, guest_token(), nil, item, [], 21, nil)

      assert %{qty: ["must be less than or equal to 20"]} = errors_on(changeset)
    end

    test "table_id is stored on the cart when provided", %{scope: scope, org: org, venue: venue} do
      item = item_fixture(scope)
      table = table_fixture(%Scope{org: org, venue: venue}, %{"number" => "5"})

      {:ok, cart} = Ordering.add_to_cart(scope, guest_token(), table.id, item, [], 1, nil)

      assert cart.table_id == table.id
    end
  end

  describe "update_item/3 and remove_item/2" do
    test "updates qty/notes on an existing line", %{scope: scope} do
      item = item_fixture(scope)
      {:ok, cart} = Ordering.add_to_cart(scope, guest_token(), nil, item, [], 1, nil)
      [line] = cart.items

      assert {:ok, updated} =
               Ordering.update_item(scope, line, %{"qty" => 3, "notes" => "well done"})

      assert updated.qty == 3
      assert updated.notes == "well done"
    end

    test "removes a line", %{scope: scope} do
      item = item_fixture(scope)
      token = guest_token()
      {:ok, cart} = Ordering.add_to_cart(scope, token, nil, item, [], 1, nil)
      [line] = cart.items

      assert :ok = Ordering.remove_item(scope, line)
      assert Ordering.get_active_cart(scope, token).items == []
    end
  end

  describe "set_kind/3" do
    test "toggles dine_in/takeaway", %{scope: scope} do
      item = item_fixture(scope)
      {:ok, cart} = Ordering.add_to_cart(scope, guest_token(), nil, item, [], 1, nil)

      assert {:ok, updated} = Ordering.set_kind(scope, cart, :takeaway)
      assert updated.kind == :takeaway
    end
  end

  describe "validate_line/2 and cart_total/2 (design-qa.md Q42)" do
    test "a line stays valid while the item's rules haven't changed", %{scope: scope} do
      item = item_fixture(scope)
      {:ok, cart} = Ordering.add_to_cart(scope, guest_token(), nil, item, [], 1, nil)
      [line] = cart.items

      assert Ordering.validate_line(scope, line) == :ok
    end

    test "a line becomes invalid when a group is later made required", %{scope: scope} do
      item = item_fixture(scope)
      group = group_fixture(scope, %{"min_selections" => 0, "max_selections" => 1})
      _option = option_fixture(scope, group)
      :ok = attach_fixture(scope, item, group)

      {:ok, cart} = Ordering.add_to_cart(scope, guest_token(), nil, item, [], 1, nil)
      [line] = cart.items
      assert Ordering.validate_line(scope, line) == :ok

      {:ok, _} =
        Catalog.update_modifier_group(scope, group, %{"min_selections" => 1, "required" => true})

      cart = Ordering.get_active_cart(scope, cart.guest_token)
      [line] = cart.items
      assert Ordering.validate_line(scope, line) == {:error, :options_changed}
    end

    test "a line becomes invalid when the item is archived after being added", %{scope: scope} do
      item = item_fixture(scope)
      {:ok, cart} = Ordering.add_to_cart(scope, guest_token(), nil, item, [], 1, nil)
      {:ok, _} = Catalog.archive_item(scope, item)

      cart = Ordering.get_active_cart(scope, cart.guest_token)
      [line] = cart.items
      assert Ordering.validate_line(scope, line) == {:error, :item_unavailable}
    end

    test "cart_total sums only structurally-valid lines, options priced in", %{scope: scope} do
      item = item_fixture(scope, %{"price" => Money.new!(:USD, "5.00")})
      group = group_fixture(scope, %{"min_selections" => 0, "max_selections" => 1})
      option = option_fixture(scope, group, %{"price_delta" => Money.new!(:USD, "1.00")})
      :ok = attach_fixture(scope, item, group)

      token = guest_token()
      {:ok, _} = Ordering.add_to_cart(scope, token, nil, item, [option.id], 2, nil)

      cart = Ordering.get_active_cart(scope, token)
      # (5.00 + 1.00) * 2 = 12.00
      assert Money.equal?(Ordering.cart_total(scope, cart), Money.new!(:USD, "12.00"))
    end

    test "cart_total excludes an invalidated line entirely", %{scope: scope} do
      item = item_fixture(scope, %{"price" => Money.new!(:USD, "5.00")})
      token = guest_token()
      {:ok, cart} = Ordering.add_to_cart(scope, token, nil, item, [], 1, nil)

      {:ok, _} = Catalog.archive_item(scope, item)
      cart = %{cart | items: Ordering.get_active_cart(scope, token).items}

      assert Money.equal?(Ordering.cart_total(scope, cart), Money.new!(:USD, "0.00"))
    end
  end

  defp checked_out_order(scope, item_or_items) do
    token = guest_token()

    item_or_items
    |> List.wrap()
    |> Enum.each(fn item ->
      {:ok, _cart} = Ordering.add_to_cart(scope, token, nil, item, [], 1, nil)
    end)

    cart = Ordering.get_active_cart(scope, token)
    {:ok, order} = Ordering.checkout(scope, cart)
    Ordering.get_order(scope, order.id)
  end

  describe "estimated_minutes/2 (build-plan.md Feature 08 ETA)" do
    test "a single item's prep_minutes, alone in the kitchen queue", %{scope: scope} do
      item = item_fixture(scope, %{"prep_minutes" => 8})
      order = checked_out_order(scope, item)

      assert Ordering.estimated_minutes(scope, order) == 8
    end

    test "takes the slowest line's prep_minutes, not the sum (items prepare in parallel)", %{
      scope: scope
    } do
      fast = item_fixture(scope, %{"name" => "Coffee", "prep_minutes" => 3})
      slow = item_fixture(scope, %{"name" => "Steak", "prep_minutes" => 20})
      order = checked_out_order(scope, [fast, slow])

      assert Ordering.estimated_minutes(scope, order) == 20
    end

    test "falls back to a static 10 minutes when no line has prep_minutes set", %{scope: scope} do
      item = item_fixture(scope)
      order = checked_out_order(scope, item)

      assert Ordering.estimated_minutes(scope, order) == 10
    end

    test "multiplies by how many orders are already in the kitchen queue", %{scope: scope} do
      item = item_fixture(scope, %{"prep_minutes" => 5})

      # Two other orders already in the kitchen pipeline occupy the queue
      # — a fresh pending_payment order isn't counted until it's placed.
      for _ <- 1..2 do
        other = checked_out_order(scope, item)
        {:ok, _} = OrderStateMachine.transition(scope, other, :placed)
      end

      order = checked_out_order(scope, item)
      assert Ordering.estimated_minutes(scope, order) == 5 * 2
    end

    test "Busy Mode's eta_inflation_factor inflates the estimate, rounded up (design-qa.md Q2)",
         %{scope: scope, venue: venue} do
      item = item_fixture(scope, %{"prep_minutes" => 10})
      order = checked_out_order(scope, item)

      {:ok, venue} = Tenants.set_eta_inflation(scope, venue, Decimal.new("1.5"))
      scope = %{scope | venue: venue}

      # 10 (prep) * 1 (queue depth) * 1.5 (inflation) = 15.
      assert Ordering.estimated_minutes(scope, order) == 15
    end
  end

  describe "tenant isolation" do
    test "one venue's guest cannot see another org's cart with the same guest_token" do
      %{venue_a: venue_a, org_a: org_a, venue_b: venue_b, org_b: org_b} = two_orgs()
      token = guest_token()

      scope_a = %Scope{org: org_a, venue: venue_a}
      Repo.put_org_id(org_a.id)
      item_a = item_fixture(scope_a)
      {:ok, _} = Ordering.add_to_cart(scope_a, token, nil, item_a, [], 1, nil)

      scope_b = %Scope{org: org_b, venue: venue_b}
      Repo.put_org_id(org_b.id)
      assert Ordering.get_active_cart(scope_b, token) == nil
    end
  end
end
