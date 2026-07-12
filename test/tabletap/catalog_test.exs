defmodule Tabletap.CatalogTest do
  use Tabletap.DataCase, async: true

  alias Tabletap.Accounts.Scope
  alias Tabletap.Catalog
  alias Tabletap.Catalog.{Category, DailyItemLimit, ModifierGroup}
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

  defp group_fixture(scope, attrs \\ %{}) do
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

  describe "modifier groups" do
    test "create_modifier_group/2 saves selection rules", %{scope: scope} do
      group =
        group_fixture(scope, %{
          "name" => "Size",
          "min_selections" => 1,
          "max_selections" => 1,
          "required" => true
        })

      assert group.name == "Size"
      assert group.min_selections == 1
      assert group.max_selections == 1
      assert group.required
    end

    test "create_modifier_group/2 rejects max below min", %{scope: scope} do
      assert {:error, changeset} =
               Catalog.create_modifier_group(scope, %{
                 "name" => "Broken",
                 "min_selections" => 3,
                 "max_selections" => 1
               })

      assert "must be greater than or equal to min selections" in errors_on(changeset).max_selections
    end

    test "create_modifier_group/2 rejects required with zero min selections", %{scope: scope} do
      assert {:error, changeset} =
               Catalog.create_modifier_group(scope, %{
                 "name" => "Broken",
                 "min_selections" => 0,
                 "max_selections" => 2,
                 "required" => true
               })

      assert "must be at least 1 when the group is required" in errors_on(changeset).min_selections
    end

    test "update_modifier_group/3 applies the same rule validations", %{scope: scope} do
      group = group_fixture(scope)

      assert {:error, changeset} =
               Catalog.update_modifier_group(scope, group, %{"max_selections" => -1})

      assert errors_on(changeset).max_selections != []
    end

    test "archive_modifier_group/2 hides it and detaches it from items", %{scope: scope} do
      category = category_fixture(scope)
      item = item_fixture(scope, category)
      group = group_fixture(scope)
      {:ok, _} = Catalog.attach_group_to_item(scope, item, group)

      assert {:ok, archived} = Catalog.archive_modifier_group(scope, group)
      assert archived.archived_at != nil

      assert Catalog.list_modifier_groups(scope) == []
      assert Catalog.list_item_modifier_groups(scope, item) == []
      assert Repo.get(ModifierGroup, group.id, skip_org_id: true)
    end
  end

  describe "modifier options" do
    test "create_modifier_option/3 casts a Money delta and appends position", %{scope: scope} do
      group = group_fixture(scope)
      first = option_fixture(scope, group, %{"name" => "Extra cheese"})
      second = option_fixture(scope, group, %{"name" => "Bacon"})

      assert first.price_delta == Money.new!(:USD, "1.00")
      assert first.position == 0
      assert second.position == 1
    end

    test "zero and negative deltas are legal", %{scope: scope} do
      group = group_fixture(scope)

      free =
        option_fixture(scope, group, %{
          "name" => "No onions",
          "price_delta" => Money.new!(:USD, 0)
        })

      discount =
        option_fixture(scope, group, %{
          "name" => "No meat",
          "price_delta" => Money.new!(:USD, "-1.00")
        })

      assert free.price_delta == Money.new!(:USD, 0)
      assert discount.price_delta == Money.new!(:USD, "-1.00")
    end

    test "archive_modifier_option/2 hides it from the group's preloaded options", %{scope: scope} do
      group = group_fixture(scope)
      option = option_fixture(scope, group)

      assert {:ok, _} = Catalog.archive_modifier_option(scope, option)
      assert %ModifierGroup{options: []} = Catalog.get_modifier_group(scope, group.id)
    end
  end

  describe "item modifier attachments" do
    test "attach_group_to_item/3 appends in attachment order", %{scope: scope} do
      category = category_fixture(scope)
      item = item_fixture(scope, category)
      extras = group_fixture(scope, %{"name" => "Extras"})
      size = group_fixture(scope, %{"name" => "Size"})

      {:ok, _} = Catalog.attach_group_to_item(scope, item, size)
      {:ok, _} = Catalog.attach_group_to_item(scope, item, extras)

      assert Catalog.list_item_modifier_groups(scope, item) |> Enum.map(& &1.name) ==
               ["Size", "Extras"]
    end

    test "attaching the same group twice returns a changeset error", %{scope: scope} do
      category = category_fixture(scope)
      item = item_fixture(scope, category)
      group = group_fixture(scope)

      {:ok, _} = Catalog.attach_group_to_item(scope, item, group)
      assert {:error, changeset} = Catalog.attach_group_to_item(scope, item, group)
      assert "is already attached to this item" in errors_on(changeset).item_id
    end

    test "detach_group_from_item/3 removes the attachment", %{scope: scope} do
      category = category_fixture(scope)
      item = item_fixture(scope, category)
      group = group_fixture(scope)

      {:ok, _} = Catalog.attach_group_to_item(scope, item, group)
      assert :ok = Catalog.detach_group_from_item(scope, item, group)
      assert Catalog.list_item_modifier_groups(scope, item) == []
    end

    test "attach refuses a group from another venue of the same org", %{scope: scope, org: org} do
      other_venue = venue_fixture(org)
      other_scope = %Scope{org: org, venue: other_venue}

      category = category_fixture(scope)
      item = item_fixture(scope, category)
      other_group = group_fixture(other_scope)

      assert {:error, :not_found} = Catalog.attach_group_to_item(scope, item, other_group)
    end
  end

  describe "price_range/2" do
    setup %{scope: scope} do
      category = category_fixture(scope)

      burger =
        item_fixture(scope, category, %{
          "name" => "Hamburger",
          "price" => Money.new!(:USD, "5.00")
        })

      %{burger: burger}
    end

    test "no groups: range collapses to the base price", %{burger: burger} do
      assert Catalog.price_range(burger, []) ==
               {Money.new!(:USD, "5.00"), Money.new!(:USD, "5.00")}
    end

    test "optional extras only raise the maximum", %{scope: scope, burger: burger} do
      cheese =
        group_fixture(scope, %{"name" => "Cheese", "min_selections" => 0, "max_selections" => 3})

      option_fixture(scope, cheese, %{
        "name" => "Extra cheese",
        "price_delta" => Money.new!(:USD, "1.00")
      })

      option_fixture(scope, cheese, %{
        "name" => "Bacon",
        "price_delta" => Money.new!(:USD, "2.00")
      })

      {:ok, _} = Catalog.attach_group_to_item(scope, burger, cheese)

      groups = Catalog.list_item_modifier_groups(scope, burger)

      assert Catalog.price_range(burger, groups) ==
               {Money.new!(:USD, "5.00"), Money.new!(:USD, "8.00")}
    end

    test "a required pick moves both bounds", %{scope: scope, burger: burger} do
      size =
        group_fixture(scope, %{
          "name" => "Size",
          "min_selections" => 1,
          "max_selections" => 1,
          "required" => true
        })

      option_fixture(scope, size, %{"name" => "Regular", "price_delta" => Money.new!(:USD, 0)})
      option_fixture(scope, size, %{"name" => "Large", "price_delta" => Money.new!(:USD, "2.00")})
      {:ok, _} = Catalog.attach_group_to_item(scope, burger, size)

      groups = Catalog.list_item_modifier_groups(scope, burger)

      assert Catalog.price_range(burger, groups) ==
               {Money.new!(:USD, "5.00"), Money.new!(:USD, "7.00")}
    end

    test "optional negative deltas lower the minimum", %{scope: scope, burger: burger} do
      remove =
        group_fixture(scope, %{"name" => "Remove", "min_selections" => 0, "max_selections" => 2})

      option_fixture(scope, remove, %{
        "name" => "No meat",
        "price_delta" => Money.new!(:USD, "-1.00")
      })

      option_fixture(scope, remove, %{"name" => "No onions", "price_delta" => Money.new!(:USD, 0)})

      {:ok, _} = Catalog.attach_group_to_item(scope, burger, remove)

      groups = Catalog.list_item_modifier_groups(scope, burger)

      assert Catalog.price_range(burger, groups) ==
               {Money.new!(:USD, "4.00"), Money.new!(:USD, "5.00")}
    end

    test "inactive options are ignored", %{scope: scope, burger: burger} do
      extras =
        group_fixture(scope, %{"name" => "Extras", "min_selections" => 0, "max_selections" => 3})

      option =
        option_fixture(scope, extras, %{
          "name" => "Truffle",
          "price_delta" => Money.new!(:USD, "9.00")
        })

      {:ok, _} = Catalog.update_modifier_option(scope, option, %{"active" => false})
      {:ok, _} = Catalog.attach_group_to_item(scope, burger, extras)

      groups = Catalog.list_item_modifier_groups(scope, burger)

      assert Catalog.price_range(burger, groups) ==
               {Money.new!(:USD, "5.00"), Money.new!(:USD, "5.00")}
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

    test "a second org cannot see or attach the first org's modifier groups" do
      %{org_a: org_a, venue_a: venue_a, org_b: org_b, venue_b: venue_b} = two_orgs()
      scope_a = %Scope{org: org_a, venue: venue_a}
      scope_b = %Scope{org: org_b, venue: venue_b}

      Repo.put_org_id(org_a.id)
      group_a = group_fixture(scope_a)

      Repo.put_org_id(org_b.id)
      category_b = category_fixture(scope_b)
      item_b = item_fixture(scope_b, category_b)

      assert Catalog.list_modifier_groups(scope_b) == []
      assert Catalog.get_modifier_group(scope_b, group_a.id) == nil
      assert {:error, :not_found} = Catalog.attach_group_to_item(scope_b, item_b, group_a)
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
