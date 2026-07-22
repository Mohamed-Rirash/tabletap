defmodule TabletapWeb.ApiEndToEndTest do
  @moduledoc """
  build-plan.md Feature 23's own literal "Verify" step, genuinely
  executed (not just described, matching this session's established
  discipline): "A scripted client (no UI) can log in, fetch a menu,
  place a paid test order, and receive the order:{id} channel events
  for every status change."

  A real client-shaped script driving every `/api/v1` surface this
  feature built, end to end, against the real router/Endpoint pipeline
  — mocked only at the one genuine external boundary this codebase
  never crosses in any test (code-standards.md: "No test hits the real
  WaafiPay API"), via `Payments.ProviderMock`. Every other step —
  auth, menu, cart, checkout, the wallet-charge Oban job, waiter
  assignment, the kitchen transitions, the served scan, and the
  `order:{id}` channel relay — is the real production code path.

  Honest scope boundary: waiter *assignment* (`Ordering.assign_waiter/3`)
  is called directly with an injected `alive?` function rather than
  through `Staffing`'s real Presence tracking or the `AssignWaiter`
  Oban job's dispatch — that plumbing predates Feature 23 (Feature 10)
  and already has its own dedicated test suite (`assignment_test.exs`
  uses the identical injection pattern); this script's job is proving
  Feature 23's own surfaces, not re-verifying Feature 10's.
  """
  use TabletapWeb.ConnCase, async: true
  use Oban.Testing, repo: Tabletap.ObanRepo

  import Mox
  import Phoenix.ChannelTest
  import Tabletap.TenantsFixtures

  alias Tabletap.Accounts
  alias Tabletap.Accounts.Scope
  alias Tabletap.Catalog
  alias Tabletap.Ordering
  alias Tabletap.Ordering.OrderStateMachine
  alias Tabletap.Payments
  alias Tabletap.Payments.Workers.ChargeOrder
  alias Tabletap.Repo
  alias Tabletap.Staffing
  alias TabletapWeb.{ApiAuth, ApiSocket}

  setup :verify_on_exit!

  defp bearer(conn, user) do
    put_req_header(conn, "authorization", "Bearer #{ApiAuth.sign_access_token(user)}")
  end

  defp all_alive(_venue_id, _membership_id), do: true

  test "a scripted mobile client: logs in, orders, pays, and watches every status change live" do
    # --- Setup: a wallet-ready venue with one on-shift waiter ---
    %{org: org, venue: venue} = org_fixture()
    venue = charges_enabled_venue_fixture(venue)
    %{user: waiter_user, membership: waiter_membership} = waiter_fixture(org, venue)

    Repo.put_org_id(org.id)
    setup_scope = %Scope{org: org, venue: venue, role: :owner}
    {:ok, category} = Catalog.create_category(setup_scope, %{"name" => "Drinks"})

    {:ok, item} =
      Catalog.create_item(setup_scope, category, %{
        "name" => "Latte",
        "price" => Money.new!(:USD, "3.50")
      })

    waiter_scope = %Scope{org: org, venue: venue, membership: waiter_membership, role: :waiter}
    {:ok, _shift} = Staffing.clock_in(waiter_scope)

    # --- 1. Log in (build-plan.md's own literal first verb) — the real
    # magic-link deep-link exchange from Commit 1, proving the mobile
    # auth foundation genuinely works, not just the guest ordering path. ---
    customer_user = Tabletap.AccountsFixtures.user_fixture()

    magic_link_token =
      Tabletap.AccountsFixtures.extract_user_token(fn url_fun ->
        Accounts.deliver_login_instructions(customer_user, url_fun)
      end)

    confirm_conn = post(build_conn(), ~p"/api/v1/auth/confirm", %{"token" => magic_link_token})
    assert %{"access_token" => access_token} = json_response(confirm_conn, 200)
    assert {:ok, %{user_id: user_id}} = ApiAuth.verify_access_token(access_token)
    assert user_id == customer_user.id

    # --- 2. Fetch the menu ---
    menu_conn = get(build_conn(), ~p"/api/v1/venues/#{venue.slug}/menu")
    assert %{"categories" => [%{"items" => [%{"id" => item_id}]}]} = json_response(menu_conn, 200)
    assert item_id == item.id

    # --- 3. Add to cart ---
    cart_conn =
      post(build_conn(), ~p"/api/v1/venues/#{venue.slug}/cart/items", %{
        "item_id" => item.id,
        "qty" => 1
      })

    assert %{"guest_token" => guest_token} = json_response(cart_conn, 200)

    # --- 4. Place the order (wallet checkout) ---
    order_conn =
      post(build_conn(), ~p"/api/v1/orders", %{
        "venue_slug" => venue.slug,
        "guest_token" => guest_token,
        "wallet_msisdn" => "252611111111"
      })

    assert %{"id" => order_id, "status" => "pending_payment"} = json_response(order_conn, 201)
    assert_enqueued(worker: ChargeOrder)

    # --- 5. Join the order:{id} channel *before* anything settles, same
    # as the real tracker's own mount-time subscribe ---
    {:ok, socket} = Phoenix.ChannelTest.connect(ApiSocket, %{})

    {:ok, _reply, socket} =
      subscribe_and_join(socket, "order:#{order_id}", %{"guest_token" => guest_token})

    # --- 6. The wallet charge actually completes (mocked at the one
    # real external boundary this whole codebase mocks) — drives
    # pending_payment -> placed ---
    scope = %Scope{org: org, venue: venue, role: :guest}
    payment = Payments.get_latest_payment_for_order(scope, order_id)

    expect(Tabletap.Payments.ProviderMock, :charge, fn _creds, _request ->
      {:ok, %{provider_txn_id: "e2e-txn-1", state: :approved}}
    end)

    assert :ok =
             perform_job(ChargeOrder, %{
               "payment_id" => payment.id,
               "org_id" => org.id,
               "wallet_msisdn" => "252611111111"
             })

    assert_push "order_updated", %{status: :placed}

    # --- 7. Real waiter-assignment algorithm — one on-shift, injected-alive
    # waiter auto-accepts (Feature 10's own solo-waiter rule) ---
    order = Ordering.get_order(scope, order_id)
    assert {:ok, _} = Ordering.assign_waiter(scope, order, &all_alive/2)
    assert_push "order_updated", %{status: :accepted}

    # --- 8. Kitchen side (no Feature 23 mobile endpoint exists for this —
    # KDS-only, build-plan.md Feature 14) — real state machine, same as
    # the KDS board's own transitions ---
    order = Ordering.get_order(waiter_scope, order_id)
    {:ok, order} = OrderStateMachine.transition(waiter_scope, order, :preparing)
    assert_push "order_updated", %{status: :preparing}

    {:ok, _order} = OrderStateMachine.transition(waiter_scope, order, :ready)
    assert_push "order_updated", %{status: :ready}

    # --- 9. The waiter scans the customer's tracker QR to serve — the
    # real Feature 23 mobile endpoint, bearer-authenticated ---
    served_conn =
      build_conn()
      |> bearer(waiter_user)
      |> post(~p"/api/v1/waiter/orders/#{order_id}/served", %{"scanned_value" => guest_token})

    assert %{"status" => "served"} = json_response(served_conn, 200)
    assert_push "order_updated", %{status: :served}

    # --- 10. Full-circle: the tracker's own REST read agrees with every
    # channel push it just received ---
    tracker_conn = get(build_conn(), ~p"/api/v1/orders/#{guest_token}")
    assert %{"status" => "served"} = json_response(tracker_conn, 200)

    leave(socket)
  end
end
