defmodule TabletapWeb.Manager.BillingLiveTest do
  @moduledoc """
  `Manager.BillingLive` at `/settings/billing` (build-plan.md Feature
  19) — owner-only, same shape as `PaymentSettingsLive`: current plan,
  itemized preview, plan change, add-venue.
  """
  use TabletapWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Tabletap.Repo
  alias Tabletap.Tenants.Membership

  describe "access control" do
    test "redirects to log in when not authenticated", %{conn: conn} do
      assert {:error, {:redirect, %{to: "/users/log-in"}}} = live(conn, ~p"/settings/billing")
    end

    test "redirects a manager away — this page is owner-only", %{conn: conn} do
      %{org: org, venue: venue} = Tabletap.TenantsFixtures.org_fixture()
      manager_user = Tabletap.AccountsFixtures.user_fixture()

      {:ok, _} =
        %Membership{}
        |> Membership.changeset(%{
          org_id: org.id,
          venue_id: venue.id,
          user_id: manager_user.id,
          role: :manager
        })
        |> Repo.insert()

      conn = log_in_user(conn, manager_user)

      assert {:error, {:redirect, %{to: "/"}}} = live(conn, ~p"/settings/billing")
    end
  end

  describe "as an owner" do
    setup :register_and_log_in_owner

    test "shows the current plan and trial status", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/settings/billing")

      assert html =~ "Billing"
      assert html =~ "Essentials"
      assert html =~ "Trialing"
    end

    test "upgrading the plan takes effect immediately", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/settings/billing")

      html = lv |> form("#change-plan-form", %{"plan" => "growth"}) |> render_submit()

      assert html =~ "Plan changed"
      assert html =~ "Growth"
    end

    test "downgrade is blocked while venue count exceeds the target cap", %{conn: conn, org: org} do
      org |> Ecto.Changeset.change(plan: :pro) |> Repo.update!()
      Tabletap.TenantsFixtures.venue_fixture(org, %{"currency" => "USD"})

      {:ok, lv, _html} = live(conn, ~p"/settings/billing")

      html = lv |> form("#change-plan-form", %{"plan" => "essentials"}) |> render_submit()

      assert html =~ "more venues than that plan allows"
    end

    test "adds a venue while under the cap", %{conn: conn, org: org} do
      org |> Ecto.Changeset.change(plan: :pro) |> Repo.update!()

      {:ok, lv, _html} = live(conn, ~p"/settings/billing")

      html =
        lv
        |> form("#add-venue-form", %{"name" => "Second Spot", "city" => "Mogadishu"})
        |> render_submit()

      assert html =~ "Second Spot added"
    end

    test "the add-venue form is hidden once the plan cap is reached", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/settings/billing")

      refute html =~ ~s(id="add-venue-form")
      assert html =~ "upgrade to add more"
    end

    test "saving a billing wallet number persists it", %{conn: conn, org: org} do
      {:ok, lv, _html} = live(conn, ~p"/settings/billing")

      html =
        lv
        |> form("#billing-wallet-form", %{"org" => %{"billing_wallet_msisdn" => "252634000000"}})
        |> render_submit()

      assert html =~ "Billing wallet saved"

      assert Repo.get!(Tabletap.Tenants.Org, org.id, skip_org_id: true).billing_wallet_msisdn ==
               "252634000000"
    end

    test "a blank billing wallet number is rejected", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/settings/billing")

      html =
        lv
        |> form("#billing-wallet-form", %{"org" => %{"billing_wallet_msisdn" => ""}})
        |> render_submit()

      assert html =~ "can&#39;t be blank"
    end

    test "the export link is always present in the danger zone", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/settings/billing")

      assert html =~ ~s(href="/settings/billing/export.zip")
    end

    test "starting offboarding shows the confirmation and hides the button", %{conn: conn} do
      {:ok, lv, html} = live(conn, ~p"/settings/billing")
      assert html =~ "Offboard this organization"

      html = lv |> element(~s(button[phx-click="initiate_offboarding"])) |> render_click()

      assert html =~ "Offboarding started"
      refute html =~ "Offboard this organization"
    end
  end
end
