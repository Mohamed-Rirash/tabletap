defmodule TabletapWeb.Manager.ModifiersLiveTest do
  use TabletapWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Tabletap.{Catalog, Repo}

  describe "access control" do
    test "redirects to log in when not authenticated", %{conn: conn} do
      assert {:error, {:redirect, %{to: "/users/log-in"}}} = live(conn, ~p"/menu/modifiers")
    end
  end

  describe "as an owner" do
    setup :register_and_log_in_owner

    setup %{org: org} do
      Repo.put_org_id(org.id)
      :ok
    end

    test "shows an empty state with no groups yet", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/menu/modifiers")
      assert html =~ "No modifier groups yet"
    end

    test "creates a group with selection rules", %{conn: conn, scope: scope} do
      {:ok, lv, _html} = live(conn, ~p"/menu/modifiers")

      html =
        lv
        |> form("#group-form",
          modifier_group: %{
            name: "Cheese",
            min_selections: 0,
            max_selections: 3
          }
        )
        |> render_submit()

      assert html =~ "Cheese"
      assert html =~ "Group saved."
      assert [%{name: "Cheese", max_selections: 3}] = Catalog.list_modifier_groups(scope)
    end

    test "rejects max below min inline", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/menu/modifiers")

      html =
        lv
        |> form("#group-form",
          modifier_group: %{name: "Broken", min_selections: 3, max_selections: 1}
        )
        |> render_submit()

      assert html =~ "must be greater than or equal to min selections"
    end

    test "rejects a required group with min 0", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/menu/modifiers")

      html =
        lv
        |> form("#group-form",
          modifier_group: %{
            name: "Broken",
            min_selections: 0,
            max_selections: 2,
            required: true
          }
        )
        |> render_submit()

      assert html =~ "must be at least 1 when the group is required"
    end

    test "adds an option with a price delta to a group", %{conn: conn, scope: scope} do
      {:ok, group} =
        Catalog.create_modifier_group(scope, %{
          "name" => "Cheese",
          "min_selections" => 0,
          "max_selections" => 3
        })

      {:ok, lv, _html} = live(conn, ~p"/menu/modifiers")

      lv |> element("button", "Add option") |> render_click(%{"group-id" => group.id})

      html =
        lv
        |> form("#option-form-#{group.id}", %{
          "option" => %{"name" => "Extra cheese", "price_delta_amount" => "1.00"}
        })
        |> render_submit()

      # The sign and the amount render as separate nodes ("+" text +
      # <.money> span), so assert them separately.
      assert html =~ "Extra cheese"
      assert html =~ "$1.00"
      assert html =~ "Option saved."

      assert [%{options: [option]}] = Catalog.list_modifier_groups(scope)
      assert option.price_delta == Money.new!(:USD, "1.00")
    end

    test "archives a group", %{conn: conn, scope: scope} do
      {:ok, group} =
        Catalog.create_modifier_group(scope, %{
          "name" => "Cheese",
          "min_selections" => 0,
          "max_selections" => 3
        })

      {:ok, lv, _html} = live(conn, ~p"/menu/modifiers")

      html =
        lv
        |> element("#modifier-group-#{group.id} button[phx-click=archive_group]")
        |> render_click()

      refute html =~ "Cheese"
      assert Catalog.list_modifier_groups(scope) == []
    end
  end

  describe "attach flow from the menu editor" do
    setup :register_and_log_in_owner

    setup %{org: org} do
      Repo.put_org_id(org.id)
      :ok
    end

    test "attaching a group shows it and the computed price range", %{conn: conn, scope: scope} do
      {:ok, category} = Catalog.create_category(scope, %{"name" => "Food"})

      {:ok, burger} =
        Catalog.create_item(scope, category, %{
          "name" => "Hamburger",
          "price" => Money.new!(:USD, "5.00")
        })

      {:ok, cheese} =
        Catalog.create_modifier_group(scope, %{
          "name" => "Cheese",
          "min_selections" => 0,
          "max_selections" => 3
        })

      {:ok, _} =
        Catalog.create_modifier_option(scope, cheese, %{
          "name" => "Extra cheese",
          "price_delta" => Money.new!(:USD, "1.00")
        })

      {:ok, lv, _html} = live(conn, ~p"/menu")

      lv
      |> element(~s(button[phx-click=open_item_form][phx-value-item-id="#{burger.id}"]))
      |> render_click()

      html =
        lv
        |> form("#attach-group-form-#{burger.id}", %{"group_id" => cheese.id})
        |> render_submit()

      assert html =~ "Cheese"
      assert html =~ "Price with options:"
      assert html =~ "$5.00"
      assert html =~ "$6.00"

      assert [%{id: attached_id}] = Catalog.list_item_modifier_groups(scope, burger)
      assert attached_id == cheese.id

      # Detach removes it again.
      html = lv |> element("button[phx-click=detach_group]") |> render_click()
      refute html =~ "Price with options:"
      assert Catalog.list_item_modifier_groups(scope, burger) == []
    end
  end
end
