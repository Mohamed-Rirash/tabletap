defmodule Tabletap.CatalogTest do
  use Tabletap.DataCase, async: true

  alias Tabletap.Accounts.Scope
  alias Tabletap.Catalog
  alias Tabletap.Catalog.{Category, DailyItemLimit}
  alias Tabletap.Repo

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

  defp item_fixture(scope, category, attrs \\ %{}) do
    {:ok, item} =
      Catalog.create_item(
        scope,
        category,
        Enum.into(attrs, %{"name" => "Latte", "price" => Money.new!(:USD, "3.50")})
      )

    item
  end

  describe "categories" do
    test "create_category/2 appends to the end of the venue's list", %{scope: scope} do
      first = category_fixture(scope, %{"name" => "Drinks"})
      second = category_fixture(scope, %{"name" => "Food"})

      assert first.position == 0
      assert second.position == 1
    end

    test "create_category/2 rejects a blank name", %{scope: scope} do
      assert {:error, changeset} = Catalog.create_category(scope, %{"name" => ""})
      assert "can't be blank" in errors_on(changeset).name
    end

    test "update_category/3 renames", %{scope: scope} do
      category = category_fixture(scope)
      assert {:ok, updated} = Catalog.update_category(scope, category, %{"name" => "Beverages"})
      assert updated.name == "Beverages"
    end

    test "archive_category/2 hides it from list_categories/1 but not the DB row", %{scope: scope} do
      category = category_fixture(scope)
      assert {:ok, archived} = Catalog.archive_category(scope, category)
      assert archived.archived_at != nil

      refute category.id in Enum.map(Catalog.list_categories(scope), & &1.id)
      assert Repo.get(Category, category.id, skip_org_id: true)
    end

    test "reorder_categories/2 resequences to match the given order", %{scope: scope} do
      a = category_fixture(scope, %{"name" => "A"})
      b = category_fixture(scope, %{"name" => "B"})
      c = category_fixture(scope, %{"name" => "C"})

      assert {:ok, _} = Catalog.reorder_categories(scope, [c.id, a.id, b.id])

      assert Catalog.list_categories(scope) |> Enum.map(& &1.id) == [c.id, a.id, b.id]
    end
  end

  describe "items" do
    test "create_item/3 casts a Money price and appends position within its category", %{
      scope: scope
    } do
      category = category_fixture(scope)
      first = item_fixture(scope, category, %{"name" => "Latte"})
      second = item_fixture(scope, category, %{"name" => "Mocha"})

      assert first.price == Money.new!(:USD, "3.50")
      assert first.position == 0
      assert second.position == 1
    end

    test "create_item/3 saves a free-text ingredients list", %{scope: scope} do
      category = category_fixture(scope)

      item =
        item_fixture(scope, category, %{"ingredients" => "Beef patty, brioche bun, cheddar"})

      assert item.ingredients == "Beef patty, brioche bun, cheddar"
    end

    test "create_item/3 rejects a zero or negative price", %{scope: scope} do
      category = category_fixture(scope)

      assert {:error, changeset} =
               Catalog.create_item(scope, category, %{
                 "name" => "Free item",
                 "price" => Money.new!(:USD, 0)
               })

      assert "must be greater than zero" in errors_on(changeset).price
    end

    test "create_item/3 rejects an unknown dietary tag", %{scope: scope} do
      category = category_fixture(scope)

      assert {:error, changeset} =
               Catalog.create_item(scope, category, %{
                 "name" => "Latte",
                 "price" => Money.new!(:USD, "3.50"),
                 "dietary_tags" => ["made_up_tag"]
               })

      assert "has an invalid entry" in errors_on(changeset).dietary_tags
    end

    test "move_item_to_category/3 moves within the same venue, appended to the end", %{
      scope: scope
    } do
      drinks = category_fixture(scope, %{"name" => "Drinks"})
      food = category_fixture(scope, %{"name" => "Food"})
      existing_food_item = item_fixture(scope, food, %{"name" => "Fries"})
      item = item_fixture(scope, drinks, %{"name" => "Latte"})

      assert {:ok, moved} = Catalog.move_item_to_category(scope, item, food)
      assert moved.category_id == food.id
      assert moved.position == existing_food_item.position + 1
    end

    test "move_item_to_category/3 refuses a category from a different venue", %{scope: scope} do
      %{venue: other_venue} = org_fixture()
      category = category_fixture(scope)
      item = item_fixture(scope, category)

      foreign_category = %Category{id: Ecto.UUID.generate(), venue_id: other_venue.id}

      assert {:error, :not_found} = Catalog.move_item_to_category(scope, item, foreign_category)
    end

    test "set_availability/3 toggles the daily flag independent of `active`", %{scope: scope} do
      category = category_fixture(scope)
      item = item_fixture(scope, category)

      assert {:ok, updated} = Catalog.set_availability(scope, item, false)
      assert updated.available_today == false
      assert updated.active == true
    end

    test "archive_item/2 hides it from list_menu/1", %{scope: scope} do
      category = category_fixture(scope)
      item = item_fixture(scope, category)

      assert {:ok, _} = Catalog.archive_item(scope, item)

      assert [{^category, []}] = Catalog.list_menu(scope)
    end

    test "reorder_items/3 resequences within a category", %{scope: scope} do
      category = category_fixture(scope)
      a = item_fixture(scope, category, %{"name" => "A"})
      b = item_fixture(scope, category, %{"name" => "B"})

      assert {:ok, _} = Catalog.reorder_items(scope, category, [b.id, a.id])

      assert [{_category, [first, second]}] = Catalog.list_menu(scope)
      assert first.id == b.id
      assert second.id == a.id
    end
  end

  describe "daily limits" do
    test "no row means unlimited", %{scope: scope} do
      category = category_fixture(scope)
      item = item_fixture(scope, category)

      assert Catalog.get_daily_limit(scope, item) == nil
    end

    test "set_daily_limit/4 creates then updates on the same business date (upsert)", %{
      scope: scope
    } do
      category = category_fixture(scope)
      item = item_fixture(scope, category)

      assert {:ok, limit} = Catalog.set_daily_limit(scope, item, 20)
      assert limit.limit_qty == 20
      assert DailyItemLimit.remaining(limit) == 20

      assert {:ok, updated} = Catalog.set_daily_limit(scope, item, 5)
      assert updated.id == limit.id
      assert updated.limit_qty == 5
    end

    test "clear_daily_limit/3 removes the row", %{scope: scope} do
      category = category_fixture(scope)
      item = item_fixture(scope, category)
      {:ok, _} = Catalog.set_daily_limit(scope, item, 20)

      assert {:ok, _} = Catalog.clear_daily_limit(scope, item)
      assert Catalog.get_daily_limit(scope, item) == nil
    end

    test "remaining/1 floors at zero, never negative", %{} do
      limit = %DailyItemLimit{limit_qty: 5, sold_qty: 4, reserved_qty: 3}
      assert DailyItemLimit.remaining(limit) == 0
    end
  end

  describe "list_public_menu/1" do
    test "excludes inactive categories, and inactive/unavailable/archived items", %{scope: scope} do
      visible_category = category_fixture(scope, %{"name" => "Visible"})
      hidden_category = category_fixture(scope, %{"name" => "Hidden", "active" => false})

      visible_item = item_fixture(scope, visible_category, %{"name" => "Visible item"})
      item_fixture(scope, visible_category, %{"name" => "Inactive item", "active" => false})

      inactive_item =
        Catalog.get_item(
          scope,
          item_fixture(scope, visible_category, %{"name" => "Off today"}).id
        )

      {:ok, _} = Catalog.set_availability(scope, inactive_item, false)
      archived_item = item_fixture(scope, visible_category, %{"name" => "Archived item"})
      {:ok, _} = Catalog.archive_item(scope, archived_item)
      item_fixture(scope, hidden_category, %{"name" => "In a hidden category"})

      assert [{category, items}] = Catalog.list_public_menu(scope)
      assert category.id == visible_category.id
      assert Enum.map(items, & &1.id) == [visible_item.id]
    end
  end

  describe "tenant isolation" do
    test "a second org cannot see the first org's categories or items" do
      %{org_a: org_a, venue_a: venue_a, org_b: org_b, venue_b: venue_b} = two_orgs()

      scope_a = %Scope{org: org_a, venue: venue_a}
      scope_b = %Scope{org: org_b, venue: venue_b}

      Repo.put_org_id(org_a.id)
      category_a = category_fixture(scope_a)
      item_fixture(scope_a, category_a)

      Repo.put_org_id(org_b.id)
      assert Catalog.list_categories(scope_b) == []
      assert Catalog.list_menu(scope_b) == []
      assert Catalog.get_item(scope_b, item_fixture(scope_a, category_a).id) == nil
    end

    test "move_item_to_category/3 refuses a category belonging to a different org's venue" do
      %{org_a: org_a, venue_a: venue_a, org_b: org_b, venue_b: venue_b} = two_orgs()
      scope_a = %Scope{org: org_a, venue: venue_a}
      scope_b = %Scope{org: org_b, venue: venue_b}

      Repo.put_org_id(org_a.id)
      category_a = category_fixture(scope_a)
      item_a = item_fixture(scope_a, category_a)

      Repo.put_org_id(org_b.id)
      category_b = category_fixture(scope_b)

      # venue_a's item, but scope_b's venue — the venue mismatch check
      # refuses it regardless of org.
      assert {:error, :not_found} = Catalog.move_item_to_category(scope_b, item_a, category_b)
    end
  end
end
