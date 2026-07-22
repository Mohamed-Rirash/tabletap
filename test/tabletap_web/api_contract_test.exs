defmodule TabletapWeb.ApiContractTest do
  @moduledoc """
  build-plan.md Feature 23 Commit 6 — "every API response schema
  snapshot-tested." Asserts the *exact* key shape of one real success
  response per endpoint via `TabletapWeb.ApiShape.assert_json_shape/2`
  — catches an accidentally added/removed/renamed field that a
  functional test's own partial pattern-match (`%{"status" => ...} =
  json_response(...)`) would silently let through.
  """
  use TabletapWeb.ConnCase, async: true

  import Tabletap.TenantsFixtures
  import TabletapWeb.ApiShape

  alias Tabletap.{Accounts, Catalog, Ordering, Repo}
  alias Tabletap.Accounts.Scope
  alias Tabletap.Ordering.{Order, OrderStateMachine}

  @money_shape %{"currency" => nil, "amount" => nil}

  @order_shape %{
    "id" => nil,
    "guest_token" => nil,
    "number" => nil,
    "status" => nil,
    "kind" => nil,
    "subtotal" => @money_shape,
    "discount_total" => @money_shape,
    "total" => @money_shape,
    "eta_minutes" => nil,
    "payment" => nil,
    "items" => [
      %{
        "id" => nil,
        "menu_item_id" => nil,
        "name" => nil,
        "qty" => nil,
        "unit_price" => @money_shape,
        "line_total" => @money_shape,
        "notes" => nil,
        "modifiers" => []
      }
    ],
    "placed_at" => nil,
    "accepted_at" => nil,
    "ready_at" => nil,
    "served_at" => nil
  }

  setup do
    %{org: org, venue: venue, user: owner} = org_fixture()
    venue = charges_enabled_venue_fixture(venue)
    %{user: waiter_user, membership: waiter_membership} = waiter_fixture(org, venue)

    Repo.put_org_id(org.id)
    scope = %Scope{org: org, venue: venue, role: :guest}
    {:ok, category} = Catalog.create_category(scope, %{"name" => "Drinks"})

    {:ok, item} =
      Catalog.create_item(scope, category, %{
        "name" => "Latte",
        "price" => Money.new!(:USD, "3.50")
      })

    %{
      org: org,
      venue: venue,
      owner: owner,
      item: item,
      waiter_user: waiter_user,
      waiter_membership: waiter_membership
    }
  end

  defp bearer(conn, user) do
    put_req_header(conn, "authorization", "Bearer #{TabletapWeb.ApiAuth.sign_access_token(user)}")
  end

  test "POST /api/v1/auth/request_magic_link" do
    user = Tabletap.AccountsFixtures.user_fixture()
    conn = post(build_conn(), ~p"/api/v1/auth/request_magic_link", %{"email" => user.email})

    assert_json_shape(json_response(conn, 200), %{"message" => nil})
  end

  test "POST /api/v1/auth/confirm and /refresh" do
    user = Tabletap.AccountsFixtures.user_fixture()

    token =
      Tabletap.AccountsFixtures.extract_user_token(fn url_fun ->
        Accounts.deliver_login_instructions(user, url_fun)
      end)

    confirm_conn = post(build_conn(), ~p"/api/v1/auth/confirm", %{"token" => token})
    confirm_body = json_response(confirm_conn, 200)

    token_shape = %{
      "access_token" => nil,
      "refresh_token" => nil,
      "expires_in" => nil,
      "user" => %{"id" => nil, "email" => nil}
    }

    assert_json_shape(confirm_body, token_shape)

    refresh_conn =
      post(build_conn(), ~p"/api/v1/auth/refresh", %{
        "refresh_token" => confirm_body["refresh_token"]
      })

    assert_json_shape(json_response(refresh_conn, 200), token_shape)
  end

  test "GET /api/v1/venues/:slug/menu", %{venue: venue} do
    conn = get(build_conn(), ~p"/api/v1/venues/#{venue.slug}/menu")

    assert_json_shape(json_response(conn, 200), %{
      "categories" => [
        %{
          "id" => nil,
          "name" => nil,
          "items" => [
            %{
              "id" => nil,
              "name" => nil,
              "description" => nil,
              "photo_url" => nil,
              "price" => @money_shape,
              "remaining" => nil,
              "dietary_tags" => [],
              "allergen_tags" => [],
              "modifier_groups" => []
            }
          ]
        }
      ]
    })
  end

  test "POST /api/v1/venues/:slug/cart/items", %{venue: venue, item: item} do
    conn =
      post(build_conn(), ~p"/api/v1/venues/#{venue.slug}/cart/items", %{
        "item_id" => item.id,
        "qty" => 1
      })

    assert_json_shape(json_response(conn, 200), %{
      "guest_token" => nil,
      "cart" => %{
        "guest_token" => nil,
        "kind" => nil,
        "items" => [
          %{
            "id" => nil,
            "menu_item_id" => nil,
            "name" => nil,
            "qty" => nil,
            "notes" => nil,
            "options" => []
          }
        ]
      }
    })
  end

  test "POST /api/v1/orders and GET /api/v1/orders/:guest_token", %{venue: venue, item: item} do
    %{"guest_token" => guest_token} =
      build_conn()
      |> post(~p"/api/v1/venues/#{venue.slug}/cart/items", %{"item_id" => item.id, "qty" => 1})
      |> json_response(200)

    create_conn =
      post(build_conn(), ~p"/api/v1/orders", %{
        "venue_slug" => venue.slug,
        "guest_token" => guest_token,
        "payment_method" => "cash"
      })

    assert_json_shape(json_response(create_conn, 201), @order_shape)

    show_conn = get(build_conn(), ~p"/api/v1/orders/#{guest_token}")
    assert_json_shape(json_response(show_conn, 200), @order_shape)
  end

  test "POST /api/v1/waiter/orders/:id/accept and /served", %{
    org: org,
    venue: venue,
    item: item,
    waiter_user: waiter_user,
    waiter_membership: waiter_membership
  } do
    %{"guest_token" => guest_token} =
      build_conn()
      |> post(~p"/api/v1/venues/#{venue.slug}/cart/items", %{"item_id" => item.id, "qty" => 1})
      |> json_response(200)

    %{"id" => order_id} =
      build_conn()
      |> post(~p"/api/v1/orders", %{
        "venue_slug" => venue.slug,
        "guest_token" => guest_token,
        "payment_method" => "cash"
      })
      |> json_response(201)

    guest_scope = %Scope{org: org, venue: venue, role: :guest}
    waiter_scope = %Scope{org: org, venue: venue, membership: waiter_membership, role: :waiter}

    {:ok, order} =
      guest_scope
      |> Ordering.get_order(order_id)
      |> Order.assign_waiter_changeset(waiter_membership.id)
      |> Repo.update()

    {:ok, order} = OrderStateMachine.transition(waiter_scope, order, :placed)

    accept_conn =
      build_conn()
      |> bearer(waiter_user)
      |> post(~p"/api/v1/waiter/orders/#{order_id}/accept")

    assert_json_shape(json_response(accept_conn, 200), @order_shape)

    order = Ordering.get_order(waiter_scope, order.id)
    {:ok, order} = OrderStateMachine.transition(waiter_scope, order, :preparing)
    {:ok, _order} = OrderStateMachine.transition(waiter_scope, order, :ready)

    served_conn =
      build_conn()
      |> bearer(waiter_user)
      |> post(~p"/api/v1/waiter/orders/#{order_id}/served", %{"scanned_value" => guest_token})

    assert_json_shape(json_response(served_conn, 200), @order_shape)
  end

  test "GET /api/v1/owner/dashboard", %{owner: owner} do
    conn = build_conn() |> bearer(owner) |> get(~p"/api/v1/owner/dashboard")

    assert_json_shape(json_response(conn, 200), %{
      "summary" => nil,
      "operations" => nil,
      "alerts" => nil,
      "kitchen_orders" => []
    })
  end
end
