defmodule TabletapWeb.Manager.MenuLiveTest do
  use TabletapWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Tabletap.{Catalog, Repo}

  describe "access control" do
    test "redirects to log in when not authenticated", %{conn: conn} do
      assert {:error, {:redirect, %{to: "/users/log-in"}}} = live(conn, ~p"/menu")
    end
  end

  describe "as an owner" do
    setup :register_and_log_in_owner

    # register_and_log_in_owner sets org_id on the connection's request
    # process; fixture setup below runs in the *test* process, which
    # needs its own Repo.put_org_id/1 to call Catalog directly.
    setup %{org: org} do
      Repo.put_org_id(org.id)
      :ok
    end

    test "shows an empty state with no categories yet", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/menu")
      assert html =~ "No categories yet"
    end

    test "creates a category", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/menu")

      html =
        lv
        |> form("form[phx-submit=save_category]", category: %{name: "Drinks"})
        |> render_submit()

      assert html =~ "Drinks"
      assert html =~ "Category saved."
    end

    test "creates an item with a price and dietary tag", %{conn: conn, scope: scope} do
      {:ok, category} = Catalog.create_category(scope, %{"name" => "Drinks"})
      {:ok, lv, _html} = live(conn, ~p"/menu")

      lv |> element("button", "Add item") |> render_click(%{"category-id" => category.id})

      html =
        lv
        |> form("form[phx-submit=save_item]", %{
          "item" => %{"name" => "Latte", "price_amount" => "3.50", "dietary_tags" => ["vegan"]}
        })
        |> render_submit()

      assert html =~ "Latte"
      assert html =~ "$3.50"
      assert html =~ "Item saved."

      assert [{^category, [item]}] = Catalog.list_menu(scope)
      assert item.dietary_tags == ["vegan"]
    end

    test "search filters items by name across categories", %{conn: conn, scope: scope} do
      {:ok, category} = Catalog.create_category(scope, %{"name" => "Drinks"})

      {:ok, _latte} =
        Catalog.create_item(scope, category, %{
          "name" => "Latte",
          "price" => Money.new!(:USD, "3.50")
        })

      {:ok, _mocha} =
        Catalog.create_item(scope, category, %{
          "name" => "Mocha",
          "price" => Money.new!(:USD, "4.00")
        })

      {:ok, lv, _html} = live(conn, ~p"/menu")

      html =
        lv
        |> form("#menu-search-form", %{"search" => "lat"})
        |> render_change()

      assert html =~ "Latte"
      refute html =~ "Mocha"
    end

    test "category pills filter which category is shown", %{conn: conn, scope: scope} do
      {:ok, drinks} = Catalog.create_category(scope, %{"name" => "Drinks"})
      {:ok, food} = Catalog.create_category(scope, %{"name" => "Food"})

      {:ok, _latte} =
        Catalog.create_item(scope, drinks, %{
          "name" => "Latte",
          "price" => Money.new!(:USD, "3.50")
        })

      {:ok, _fries} =
        Catalog.create_item(scope, food, %{"name" => "Fries", "price" => Money.new!(:USD, "2.50")})

      {:ok, lv, _html} = live(conn, ~p"/menu")

      html = lv |> element("button", "Food") |> render_click()

      assert html =~ "Fries"
      refute html =~ "Latte"
    end

    test "the edit modal shows the quantity/daily-limit section for an existing item", %{
      conn: conn,
      scope: scope
    } do
      {:ok, category} = Catalog.create_category(scope, %{"name" => "Drinks"})

      {:ok, item} =
        Catalog.create_item(scope, category, %{
          "name" => "Latte",
          "price" => Money.new!(:USD, "3.50")
        })

      {:ok, lv, _html} = live(conn, ~p"/menu")

      html =
        lv
        |> element("button[phx-value-item-id='#{item.id}']", "Edit")
        |> render_click()

      assert html =~ "Quantity available today"
      assert html =~ "No daily limit"
    end

    test "the Preview tab shows the card grid with ingredients", %{conn: conn, scope: scope} do
      {:ok, category} = Catalog.create_category(scope, %{"name" => "Drinks"})

      {:ok, _item} =
        Catalog.create_item(scope, category, %{
          "name" => "Latte",
          "price" => Money.new!(:USD, "3.50"),
          "ingredients" => "Espresso, steamed milk"
        })

      {:ok, lv, _html} = live(conn, ~p"/menu")

      html = lv |> element("button", "Preview") |> render_click()

      assert html =~ "Latte"
      assert html =~ "Espresso, steamed milk"
      assert html =~ "$3.50"
    end

    test "clicking a Preview card opens a read-only detail view", %{conn: conn, scope: scope} do
      {:ok, category} = Catalog.create_category(scope, %{"name" => "Drinks"})

      {:ok, item} =
        Catalog.create_item(scope, category, %{
          "name" => "Latte",
          "description" => "Rich and creamy",
          "price" => Money.new!(:USD, "3.50"),
          "ingredients" => "Espresso, steamed milk"
        })

      {:ok, lv, _html} = live(conn, ~p"/menu")

      lv |> element("button", "Preview") |> render_click()
      html = lv |> element("div[phx-click=preview_item]") |> render_click(%{"id" => item.id})

      assert html =~ "Rich and creamy"
      assert html =~ "Espresso, steamed milk"
      # Read-only — no edit form fields in this view.
      refute html =~ "phx-submit=\"save_item\""
    end

    test "an unavailable item shows &quot;Off today&quot; in the Preview grid", %{
      conn: conn,
      scope: scope
    } do
      {:ok, category} = Catalog.create_category(scope, %{"name" => "Drinks"})

      {:ok, item} =
        Catalog.create_item(scope, category, %{
          "name" => "Latte",
          "price" => Money.new!(:USD, "3.50")
        })

      {:ok, _} = Catalog.set_availability(scope, item, false)

      {:ok, lv, _html} = live(conn, ~p"/menu")
      html = lv |> element("button", "Preview") |> render_click()

      assert html =~ "Off today"
    end

    test "rejects an invalid price", %{conn: conn, scope: scope} do
      {:ok, category} = Catalog.create_category(scope, %{"name" => "Drinks"})
      {:ok, lv, _html} = live(conn, ~p"/menu")

      lv |> element("button", "Add item") |> render_click(%{"category-id" => category.id})

      html =
        lv
        |> form("form[phx-submit=save_item]", %{
          "item" => %{"name" => "Latte", "price_amount" => "not-a-number"}
        })
        |> render_submit()

      assert html =~ "must be a valid amount"
      assert Catalog.list_menu(scope) == [{category, []}]
    end

    test "toggles an item off for today", %{conn: conn, scope: scope} do
      {:ok, category} = Catalog.create_category(scope, %{"name" => "Drinks"})

      {:ok, item} =
        Catalog.create_item(scope, category, %{
          "name" => "Latte",
          "price" => Money.new!(:USD, "3.50")
        })

      {:ok, lv, _html} = live(conn, ~p"/menu")

      html = lv |> element("button", "Turn off today") |> render_click()

      assert html =~ "Off today"
      assert Catalog.get_item(scope, item.id).available_today == false
    end

    test "archives a category", %{conn: conn, scope: scope} do
      {:ok, category} = Catalog.create_category(scope, %{"name" => "Beverages"})
      {:ok, lv, _html} = live(conn, ~p"/menu")

      html = lv |> element("button", "Archive") |> render_click()

      refute html =~ "Beverages"
      refute category.id in Enum.map(Catalog.list_categories(scope), & &1.id)
    end

    test "sets a daily limit", %{conn: conn, scope: scope} do
      {:ok, category} = Catalog.create_category(scope, %{"name" => "Drinks"})

      {:ok, _item} =
        Catalog.create_item(scope, category, %{
          "name" => "Latte",
          "price" => Money.new!(:USD, "3.50")
        })

      {:ok, lv, _html} = live(conn, ~p"/menu")

      html =
        lv
        |> element("form[phx-submit=save_daily_limit]")
        |> render_submit(%{"limit_qty" => "20"})

      assert html =~ "20 of 20 left today"
    end
  end
end
