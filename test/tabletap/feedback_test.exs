defmodule Tabletap.FeedbackTest do
  @moduledoc """
  Build-plan.md Feature 17 — `Tabletap.Feedback`: rating a served order
  line, the DB-enforced one-rating-per-item invariant, live-broadcast on
  submit, and the two read paths (`ratings_summary_for_items/2` for the
  public menu grid, `list_venue_feedback/1` for the manager screen).
  """
  use Tabletap.DataCase, async: true

  import Tabletap.TenantsFixtures

  alias Tabletap.Accounts.Scope
  alias Tabletap.Catalog
  alias Tabletap.Feedback
  alias Tabletap.Ordering
  alias Tabletap.Ordering.{Cart, OrderStateMachine}
  alias Tabletap.Repo

  setup do
    %{org: org, venue: venue} = org_fixture()
    Repo.put_org_id(org.id)
    scope = %Scope{org: org, venue: venue, role: :guest}

    {:ok, category} = Catalog.create_category(scope, %{"name" => "Drinks"})

    {:ok, item} =
      Catalog.create_item(scope, category, %{
        "name" => "Latte",
        "price" => Money.new!(:USD, "3.50")
      })

    %{scope: scope, venue: venue, item: item}
  end

  @forward_path [:placed, :accepted, :preparing, :ready, :served]

  defp order_fixture(scope, item, target_status) do
    token = Cart.generate_guest_token()
    {:ok, cart} = Ordering.add_to_cart(scope, token, nil, item, [], 1, nil)
    {:ok, order} = Ordering.checkout(scope, cart)

    order =
      @forward_path
      |> Enum.take_while(&(&1 != target_status))
      |> Kernel.++([target_status])
      |> Enum.reduce(order, fn status, acc ->
        {:ok, moved} = OrderStateMachine.transition(scope, acc, status)
        moved
      end)

    Repo.preload(order, :items)
  end

  describe "rate_item/5" do
    test "rates a served order's item", %{scope: scope, item: item} do
      order = order_fixture(scope, item, :served)
      [order_item] = order.items

      assert {:ok, rating} = Feedback.rate_item(scope, order, order_item, 5, comment: "Lovely!")
      assert rating.stars == 5
      assert rating.comment == "Lovely!"
      assert rating.menu_item_id == item.id
      assert rating.customer_user_id == nil
    end

    test "a closed order (served's own follow-up) is still rateable", %{scope: scope, item: item} do
      order = order_fixture(scope, item, :served)
      {:ok, closed} = OrderStateMachine.transition(scope, order, :closed)
      [order_item] = order.items

      assert {:ok, _rating} = Feedback.rate_item(scope, closed, order_item, 4)
    end

    test "rejects rating before the order is served", %{scope: scope, item: item} do
      order = order_fixture(scope, item, :preparing)
      [order_item] = order.items

      assert {:error, :not_yet_served} = Feedback.rate_item(scope, order, order_item, 5)
    end

    test "rejects a second rating for the same order item", %{scope: scope, item: item} do
      order = order_fixture(scope, item, :served)
      [order_item] = order.items

      assert {:ok, _} = Feedback.rate_item(scope, order, order_item, 5)
      assert {:error, :already_rated} = Feedback.rate_item(scope, order, order_item, 1)
    end

    test "rejects stars outside 1..5", %{scope: scope, item: item} do
      order = order_fixture(scope, item, :served)
      [order_item] = order.items

      assert {:error, changeset} = Feedback.rate_item(scope, order, order_item, 6)
      assert "is invalid" in errors_on(changeset).stars
    end

    test "broadcasts on the venue's ratings topic", %{scope: scope, venue: venue, item: item} do
      order = order_fixture(scope, item, :served)
      [order_item] = order.items
      Phoenix.PubSub.subscribe(Tabletap.PubSub, "venue:#{venue.id}:ratings")

      {:ok, _rating} = Feedback.rate_item(scope, order, order_item, 5)

      menu_item_id = item.id
      assert_received {:rating_submitted, ^menu_item_id}
    end
  end

  describe "rated_order_item_ids/2" do
    test "returns only the ids that already have a rating", %{scope: scope, item: item} do
      order1 = order_fixture(scope, item, :served)
      order2 = order_fixture(scope, item, :served)
      [item1] = order1.items
      [item2] = order2.items

      {:ok, _} = Feedback.rate_item(scope, order1, item1, 5)

      ids = Feedback.rated_order_item_ids(scope, [item1.id, item2.id])
      assert ids == MapSet.new([item1.id])
    end
  end

  describe "ratings_summary_for_items/2" do
    test "avg + count per menu item, missing entries for unrated items", %{
      scope: scope,
      venue: venue,
      item: item
    } do
      order1 = order_fixture(scope, item, :served)
      order2 = order_fixture(scope, item, :served)
      [item1] = order1.items
      [item2] = order2.items

      {:ok, _} = Feedback.rate_item(scope, order1, item1, 5)
      {:ok, _} = Feedback.rate_item(scope, order2, item2, 3)

      {:ok, category} = Catalog.create_category(scope, %{"name" => "Snacks"})

      {:ok, unrated_item} =
        Catalog.create_item(scope, category, %{
          "name" => "Chips",
          "price" => Money.new!(:USD, "1.50")
        })

      summary = Feedback.ratings_summary_for_items(scope, [item.id, unrated_item.id])

      assert Decimal.equal?(summary[item.id].avg, Decimal.new("4.0"))
      assert summary[item.id].count == 2
      refute Map.has_key?(summary, unrated_item.id)
      _ = venue
    end
  end

  describe "list_venue_feedback/1" do
    test "newest first, order/menu-item context preloaded", %{scope: scope, item: item} do
      order1 = order_fixture(scope, item, :served)
      order2 = order_fixture(scope, item, :served)
      [item1] = order1.items
      [item2] = order2.items

      {:ok, first} = Feedback.rate_item(scope, order1, item1, 4, comment: "Good")
      {:ok, second} = Feedback.rate_item(scope, order2, item2, 2, comment: "Meh")

      # `inserted_at` is second-precision, so two ratings in the same test
      # can legitimately tie — assert the tie-broken-by-id order the query
      # actually produces rather than assuming wall-clock insertion order.
      expected = Enum.sort_by([first, second], & &1.id, :desc)

      assert Feedback.list_venue_feedback(scope) |> Enum.map(& &1.id) ==
               Enum.map(expected, & &1.id)

      [newest | _] = Feedback.list_venue_feedback(scope)
      assert newest.order_item.menu_item.name == "Latte"
    end

    test "never returns another venue's feedback", %{scope: scope, item: item} do
      order = order_fixture(scope, item, :served)
      [order_item] = order.items
      {:ok, _} = Feedback.rate_item(scope, order, order_item, 5)

      %{org: other_org, venue: other_venue} = org_fixture()
      Repo.put_org_id(other_org.id)
      other_scope = %Scope{org: other_org, venue: other_venue, role: :guest}

      assert Feedback.list_venue_feedback(other_scope) == []
    end
  end
end
