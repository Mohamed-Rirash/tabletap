defmodule Tabletap.TenantsFixtures do
  @moduledoc """
  Test helpers for creating entities via `Tabletap.Tenants` — referenced by
  the `org` scope's `test_data_fixture` in config.exs (library-docs.md
  "Phoenix 1.8 Scopes").
  """

  alias Tabletap.Accounts.Scope
  alias Tabletap.Repo
  alias Tabletap.Tenants
  alias Tabletap.Tenants.{Org, Venue}

  def unique_email, do: "owner#{System.unique_integer()}@example.com"
  def valid_password, do: "hello world!"
  def unique_business_name, do: "Cadaani Coffee #{System.unique_integer()}"

  def valid_org_signup_attrs(attrs \\ %{}) do
    Enum.into(attrs, %{
      "business_name" => unique_business_name(),
      "city" => "Hargeisa",
      "email" => unique_email(),
      "password" => valid_password(),
      "password_confirmation" => valid_password()
    })
  end

  @doc """
  Creates a fresh org + first venue + owner user + owner membership —
  the one way an org ever comes into being (Tenants.create_org_with_owner/1).
  """
  def org_fixture(attrs \\ %{}) do
    {:ok, result} =
      attrs
      |> valid_org_signup_attrs()
      |> Tenants.create_org_with_owner()

    result
  end

  @doc """
  Adds a second venue to an existing org — bypasses the (not-yet-built)
  "add a venue" LiveView, for tests that need a multi-venue org (the venue
  switcher, Pro-tier scenarios).
  """
  def venue_fixture(%Org{} = org, attrs \\ %{}) do
    attrs =
      Enum.into(attrs, %{
        "name" => "Second Venue #{System.unique_integer()}",
        "currency" => "USD",
        "timezone" => "Africa/Mogadishu"
      })

    {:ok, venue} =
      %Venue{org_id: org.id}
      |> Venue.registration_changeset(attrs)
      |> Repo.insert()

    venue
  end

  @doc """
  Marks a venue as payment-ready — bypasses the real onboarding flow
  (Manager.PaymentSettingsLive + a real `Payments.verify_credentials/2`
  round-trip) for tests that only care about what happens once a venue
  *is* live, not how it got there.
  """
  def charges_enabled_venue_fixture(%Venue{} = venue) do
    {:ok, venue} =
      venue
      |> Ecto.Changeset.change(
        payment_provider: :waafipay,
        charges_enabled: true,
        waafipay_merchant_uid: "test-merchant-uid",
        waafipay_api_user_id: "test-api-user-id",
        waafipay_api_key: "test-api-key"
      )
      |> Repo.update()

    venue
  end

  @doc "Creates a table in a scope's venue via `Tenants.create_table/2`."
  def table_fixture(%Scope{} = scope, attrs \\ %{}) do
    {:ok, table} =
      Tenants.create_table(
        scope,
        Enum.into(attrs, %{"number" => "#{System.unique_integer([:positive])}"})
      )

    table
  end

  @doc """
  Two completely separate orgs (each with its own owner + first venue) —
  the standard fixture for "second tenant cannot see/touch this" tests
  (code-standards.md "Tenancy Rules": "every new context gets at least one
  ... test. Use the `two_orgs` fixture").
  """
  def two_orgs do
    %{user: owner_a, org: org_a, venue: venue_a} = org_fixture()
    %{user: owner_b, org: org_b, venue: venue_b} = org_fixture()

    %{
      owner_a: owner_a,
      org_a: org_a,
      venue_a: venue_a,
      owner_b: owner_b,
      org_b: org_b,
      venue_b: venue_b
    }
  end
end
