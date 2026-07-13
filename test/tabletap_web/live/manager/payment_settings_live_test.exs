defmodule TabletapWeb.Manager.PaymentSettingsLiveTest do
  @moduledoc """
  `Manager.PaymentSettingsLive` — owner-only (role-features.md "Payment
  account" is Owner back-office, not Manager); provider calls mocked via
  `Payments.ProviderMock` (code-standards.md).
  """
  use TabletapWeb.ConnCase, async: true

  import Mox
  import Phoenix.LiveViewTest

  alias Tabletap.Payments.ProviderMock
  alias Tabletap.Tenants.Membership

  setup :verify_on_exit!

  describe "access control" do
    test "redirects to log in when not authenticated", %{conn: conn} do
      assert {:error, {:redirect, %{to: "/users/log-in"}}} = live(conn, ~p"/settings/payments")
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
        |> Tabletap.Repo.insert()

      conn = log_in_user(conn, manager_user)

      assert {:error, {:redirect, %{to: "/"}}} = live(conn, ~p"/settings/payments")
    end
  end

  describe "as an owner" do
    setup :register_and_log_in_owner

    test "shows the not-live status with no credentials on file", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/settings/payments")

      assert html =~ "No credentials on file yet"
      assert html =~ "Not live"
    end

    test "saving credentials shows the unverified state, not live yet", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/settings/payments")

      html =
        lv
        |> form("#payment-settings-form", %{
          "venue" => %{
            "waafipay_merchant_uid" => "muid-1",
            "waafipay_api_user_id" => "auid-1",
            "waafipay_api_key" => "akey-1"
          }
        })
        |> render_submit()

      assert html =~ "Credentials saved but not verified yet"
      assert html =~ "Not live"
    end

    test "verifying after a successful lookup flips the venue live", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/settings/payments")

      lv
      |> form("#payment-settings-form", %{
        "venue" => %{
          "waafipay_merchant_uid" => "muid-1",
          "waafipay_api_user_id" => "auid-1",
          "waafipay_api_key" => "akey-1"
        }
      })
      |> render_submit()

      expect(ProviderMock, :lookup, fn _creds, _ref ->
        {:ok, %{provider_txn_id: nil, state: :pending}}
      end)

      html = lv |> element(~s([phx-click="verify"])) |> render_click()

      assert html =~ "Live — this venue can accept payments"
    end

    test "a failed verification keeps the venue not live", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/settings/payments")

      lv
      |> form("#payment-settings-form", %{
        "venue" => %{
          "waafipay_merchant_uid" => "muid-1",
          "waafipay_api_user_id" => "auid-1",
          "waafipay_api_key" => "akey-1"
        }
      })
      |> render_submit()

      expect(ProviderMock, :lookup, fn _creds, _ref -> {:error, :invalid_credentials} end)

      html = lv |> element(~s([phx-click="verify"])) |> render_click()

      assert html =~ "Verification failed"
      refute html =~ "Live — this venue can accept payments"
    end
  end
end
