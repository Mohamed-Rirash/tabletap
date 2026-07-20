defmodule Tabletap.Analytics.Workers.SendScheduledReportsTest do
  @moduledoc """
  Build-plan.md Feature 18's scheduled report delivery: a due
  subscription gets emailed with its report attached as CSV and
  `last_sent_at` stamped; a subscription belonging to a deactivated or
  demoted membership is skipped (design-qa.md Q52's send-time
  re-check).
  """
  use Tabletap.DataCase, async: true
  use Oban.Testing, repo: Tabletap.ObanRepo

  import Tabletap.TenantsFixtures
  import Swoosh.TestAssertions

  alias Tabletap.Accounts.Scope
  alias Tabletap.Analytics.Reports
  alias Tabletap.Analytics.Workers.SendScheduledReports
  alias Tabletap.{Catalog, Ordering, Payments, Repo}

  setup do
    %{org: org, venue: venue, membership: owner, user: owner_user} = org_fixture()
    Repo.put_org_id(org.id)
    scope = %Scope{org: org, venue: venue, role: :owner, membership: owner}

    {:ok, category} = Catalog.create_category(scope, %{"name" => "Drinks"})

    {:ok, item} =
      Catalog.create_item(scope, category, %{
        "name" => "Latte",
        "price" => Money.new!(:USD, "3.50")
      })

    %{org: org, venue: venue, scope: scope, owner: owner, owner_user: owner_user, item: item}
  end

  defp checked_out(scope, item) do
    token = Ordering.Cart.generate_guest_token()
    {:ok, cart} = Ordering.add_to_cart(scope, token, nil, item, [], 1, nil)
    {:ok, order} = Ordering.checkout(scope, cart)
    order
  end

  # `cashier_fixture/2` creates a fresh staff login (`AccountsFixtures.user_fixture/1`),
  # which sends its own "Log in instructions" email — drain that before
  # asserting on the scheduled-report delivery below, or
  # `assert_email_sent/1`'s `assert_received` grabs whichever `{:email,
  # _}` message is oldest in the mailbox rather than the one we care about.
  defp flush_test_mailbox do
    receive do
      {:email, _} -> flush_test_mailbox()
    after
      0 -> :ok
    end
  end

  test "emails a due subscription its report and stamps last_sent_at", %{
    scope: scope,
    owner_user: owner_user,
    item: item
  } do
    %{membership: cashier} = cashier_fixture(scope.org, scope.venue)
    cashier_scope = %{scope | role: :cashier, membership: cashier}
    order = checked_out(cashier_scope, item)
    {:ok, _} = Payments.settle_cash_now(cashier_scope, order, cashier)
    flush_test_mailbox()

    {:ok, subscription} = Reports.subscribe(scope, :revenue, :daily)

    assert :ok = perform_job(SendScheduledReports, %{})

    assert [reloaded] = Reports.list_subscriptions(scope)
    assert reloaded.id == subscription.id
    assert reloaded.last_sent_at != nil

    assert_email_sent(to: owner_user.email)
  end

  test "skips a subscription whose membership is no longer active", %{scope: scope} do
    {:ok, subscription} = Reports.subscribe(scope, :revenue, :daily)

    scope.membership
    |> Ecto.Changeset.change(active: false)
    |> Repo.update!()

    assert :ok = perform_job(SendScheduledReports, %{})

    assert [reloaded] = Reports.list_subscriptions(scope)
    assert reloaded.id == subscription.id
    assert reloaded.last_sent_at == nil
    assert_no_email_sent()
  end

  test "skips a subscription whose membership no longer has manager/owner access", %{scope: scope} do
    {:ok, subscription} = Reports.subscribe(scope, :revenue, :daily)

    scope.membership
    |> Ecto.Changeset.change(role: :waiter)
    |> Repo.update!()

    assert :ok = perform_job(SendScheduledReports, %{})

    assert [reloaded] = Reports.list_subscriptions(scope)
    assert reloaded.id == subscription.id
    assert reloaded.last_sent_at == nil
    assert_no_email_sent()
  end
end
