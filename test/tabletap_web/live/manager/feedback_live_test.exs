defmodule TabletapWeb.Manager.FeedbackLiveTest do
  @moduledoc """
  `TabletapWeb.Manager.FeedbackLive` at `/feedback` (build-plan.md
  Feature 17) — covers the feature's own verify step: "Rating from the
  customer phone appears on the manager screen live."
  """
  use TabletapWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Tabletap.Accounts.Scope
  alias Tabletap.{Catalog, Feedback, Ordering, Repo}
  alias Tabletap.Ordering.OrderStateMachine

  describe "access control" do
    test "redirects to log in when not authenticated", %{conn: conn} do
      assert {:error, {:redirect, %{to: "/users/log-in"}}} = live(conn, ~p"/feedback")
    end
  end

  describe "as an owner" do
    setup :register_and_log_in_owner

    setup %{org: org, venue: venue} do
      Repo.put_org_id(org.id)
      scope = %Scope{org: org, venue: venue}

      {:ok, category} = Catalog.create_category(scope, %{"name" => "Drinks"})

      {:ok, item} =
        Catalog.create_item(scope, category, %{
          "name" => "Latte",
          "price" => Money.new!(:USD, "3.50")
        })

      %{scope: scope, item: item}
    end

    defp served_order_item(scope, item) do
      token = Ordering.Cart.generate_guest_token()
      {:ok, cart} = Ordering.add_to_cart(scope, token, nil, item, [], 1, nil)
      {:ok, order} = Ordering.checkout(scope, cart)

      order =
        Enum.reduce([:placed, :accepted, :preparing, :ready, :served], order, fn status, acc ->
          {:ok, moved} = OrderStateMachine.transition(scope, acc, status)
          moved
        end)

      [order_item] = Repo.preload(order, :items).items
      {order, order_item}
    end

    test "shows the empty state with no ratings yet", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/feedback")

      assert html =~ "No ratings yet."
    end

    test "lists a rating with item name, order number, stars, and comment", %{
      conn: conn,
      scope: scope,
      item: item
    } do
      {order, order_item} = served_order_item(scope, item)
      {:ok, _} = Feedback.rate_item(scope, order, order_item, 4, comment: "Great coffee!")

      {:ok, _lv, html} = live(conn, ~p"/feedback")

      assert html =~ item.name
      assert html =~ "##{order.number}"
      assert html =~ "Great coffee!"
      refute html =~ "No ratings yet."
    end

    test "a new rating appears live without a page refresh", %{
      conn: conn,
      scope: scope,
      item: item
    } do
      {:ok, lv, html} = live(conn, ~p"/feedback")
      assert html =~ "No ratings yet."

      {order, order_item} = served_order_item(scope, item)
      {:ok, _} = Feedback.rate_item(scope, order, order_item, 5, comment: "Perfect")

      html = render(lv)
      assert html =~ "Perfect"
      refute html =~ "No ratings yet."
    end
  end
end
