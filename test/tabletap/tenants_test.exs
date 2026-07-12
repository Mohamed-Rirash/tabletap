defmodule Tabletap.TenantsTest do
  use Tabletap.DataCase, async: true

  alias Tabletap.Accounts.Scope
  alias Tabletap.Tenants
  alias Tabletap.Tenants.{Membership, Org, StaffInvite, Venue}

  import Tabletap.TenantsFixtures

  describe "create_org_with_owner/1" do
    test "creates an org, its first venue, an owner user, and an owner membership" do
      attrs = valid_org_signup_attrs(%{"business_name" => "Cadaani Coffee", "city" => "Jigjiga"})

      assert {:ok, %{user: user, org: org, venue: venue, membership: membership}} =
               Tenants.create_org_with_owner(attrs)

      assert org.name == "Cadaani Coffee"
      assert org.plan == :essentials
      assert org.subscription_status == :trialing
      assert_in_delta DateTime.diff(org.trial_ends_at, DateTime.utc_now(), :day), 14, 1

      assert venue.org_id == org.id
      assert venue.name == "Cadaani Coffee"
      # Jigjiga (Phase C, design-qa.md Q60) resolves to ETB.
      assert venue.currency == "ETB"
      assert venue.timezone == "Africa/Addis_Ababa"

      assert membership.org_id == org.id
      assert membership.user_id == user.id
      assert membership.role == :owner
      assert membership.venue_id == nil

      assert user.email == attrs["email"]
      assert user.confirmed_at != nil
      assert user.hashed_password != nil
    end

    test "Hargeisa and Mogadishu resolve to USD" do
      assert {:ok, %{venue: venue}} =
               valid_org_signup_attrs(%{"city" => "Hargeisa"}) |> Tenants.create_org_with_owner()

      assert venue.currency == "USD"

      assert {:ok, %{venue: venue}} =
               valid_org_signup_attrs(%{"city" => "Mogadishu"}) |> Tenants.create_org_with_owner()

      assert venue.currency == "USD"
    end

    test "rejects an unrecognized city instead of silently defaulting" do
      assert {:error, %Ecto.Changeset{} = changeset} =
               valid_org_signup_attrs(%{"city" => "Nairobi"}) |> Tenants.create_org_with_owner()

      assert "is not a supported launch city" in errors_on(changeset).city

      # Nothing was created — not even under the wrong (defaulted) city.
      assert Repo.aggregate(Org, :count, skip_org_id: true) == 0
    end

    test "rejects a missing city the same way" do
      attrs = valid_org_signup_attrs() |> Map.delete("city")

      assert {:error, %Ecto.Changeset{} = changeset} = Tenants.create_org_with_owner(attrs)
      assert "is not a supported launch city" in errors_on(changeset).city
    end

    test "rolls back everything when the email is already taken" do
      %{user: existing_user} = org_fixture()

      assert {:error, %Ecto.Changeset{} = changeset} =
               valid_org_signup_attrs(%{"email" => existing_user.email})
               |> Tenants.create_org_with_owner()

      assert "has already been taken" in errors_on(changeset).email

      # No stray org/venue left behind by the aborted transaction.
      assert Repo.aggregate(Org, :count, skip_org_id: true) == 1
    end

    test "requires a password" do
      assert {:error, %Ecto.Changeset{} = changeset} =
               valid_org_signup_attrs(%{"password" => "", "password_confirmation" => ""})
               |> Tenants.create_org_with_owner()

      assert "can't be blank" in errors_on(changeset).password
    end
  end

  describe "tenant isolation" do
    test "two seeded orgs cannot see each other's venues through list_venues/1" do
      %{org_a: org_a, venue_a: venue_a, org_b: org_b, venue_b: venue_b} = two_orgs()

      scope_a = %Scope{org: org_a}
      scope_b = %Scope{org: org_b}

      Repo.put_org_id(org_a.id)
      assert [%Venue{id: id}] = Tenants.list_venues(scope_a)
      assert id == venue_a.id
      refute id == venue_b.id

      Repo.put_org_id(org_b.id)
      assert [%Venue{id: id}] = Tenants.list_venues(scope_b)
      assert id == venue_b.id
    end

    test "switch_venue/2 refuses a venue from a different org" do
      %{org_a: org_a, venue_b: venue_b} = two_orgs()

      scope_a = %Scope{org: org_a}

      assert {:error, :not_found} = Tenants.switch_venue(scope_a, venue_b.id)
    end

    test "switch_venue/2 refuses an archived venue even within the same org" do
      %{org: org, venue: venue} = org_fixture()

      {:ok, venue} =
        venue
        |> Ecto.Changeset.change(archived_at: DateTime.utc_now(:second))
        |> Repo.update()

      scope = %Scope{org: org}

      assert {:error, :not_found} = Tenants.switch_venue(scope, venue.id)
    end

    test "a membership can never point at another org's venue (composite FK)" do
      %{org_a: org_a, venue_b: venue_b, owner_b: owner_b} = two_orgs()

      changeset =
        Membership.changeset(%Membership{}, %{
          org_id: org_a.id,
          venue_id: venue_b.id,
          user_id: owner_b.id,
          role: :manager
        })

      assert {:error, changeset} = Repo.insert(changeset)
      assert "does not exist" in errors_on(changeset).venue_id
    end

    test "a staff invite can never point at another org's venue (composite FK)" do
      %{org_a: org_a, venue_b: venue_b} = two_orgs()

      changeset =
        StaffInvite.changeset(%StaffInvite{}, %{
          org_id: org_a.id,
          venue_id: venue_b.id,
          email: unique_email(),
          role: :waiter
        })

      assert {:error, changeset} = Repo.insert(changeset)
      assert "does not exist" in errors_on(changeset).venue_id
    end

    test "a user can never hold two owner memberships in the same org (partial unique index)" do
      %{org: org, user: owner} = org_fixture()

      changeset =
        Membership.changeset(%Membership{}, %{
          org_id: org.id,
          venue_id: nil,
          user_id: owner.id,
          role: :owner
        })

      assert {:error, changeset} = Repo.insert(changeset)
      assert "is already an owner of this organization" in errors_on(changeset).org_id
    end
  end

  describe "build_scope/2" do
    test "resolves an owner's org, venue, membership, and role" do
      %{user: user, org: org, venue: venue} = org_fixture()

      scope = Tenants.build_scope(user, %{})

      assert scope.user.id == user.id
      assert scope.org.id == org.id
      assert scope.venue.id == venue.id
      assert scope.role == :owner
    end

    test "a user with no memberships gets org/venue/role: nil, not a crash" do
      user = Tabletap.AccountsFixtures.user_fixture()

      scope = Tenants.build_scope(user, %{})

      assert scope.user.id == user.id
      assert scope.org == nil
      assert scope.venue == nil
      assert scope.role == nil
    end

    test "nil user returns nil (matches Scope.for_user(nil))" do
      assert Tenants.build_scope(nil, %{}) == nil
    end

    test "an owner with multiple venues honors current_venue_id from the session" do
      %{org: org, venue: first_venue, user: user} = org_fixture()
      second_venue = venue_fixture(org)

      scope = Tenants.build_scope(user, %{"current_venue_id" => second_venue.id})
      assert scope.venue.id == second_venue.id

      scope = Tenants.build_scope(user, %{})
      assert scope.venue.id == first_venue.id
    end
  end

  describe "staff invites" do
    test "create_staff_invite/3 creates a pending invite for a venue in the current org" do
      %{org: org, venue: venue} = org_fixture()
      scope = %Scope{org: org}
      email = unique_email()

      assert {:ok, %StaffInvite{} = invite} =
               Tenants.create_staff_invite(scope, venue.id, %{
                 "email" => email,
                 "role" => "waiter"
               })

      assert invite.org_id == org.id
      assert invite.venue_id == venue.id
      assert invite.email == email
      assert invite.role == :waiter
      assert invite.token
      assert invite.accepted_at == nil
      assert DateTime.compare(invite.expires_at, DateTime.utc_now()) == :gt
    end

    test "create_staff_invite/3 refuses a venue from a different org (composite FK)" do
      %{org_a: org_a, venue_b: venue_b} = two_orgs()
      scope_a = %Scope{org: org_a}

      assert {:error, changeset} =
               Tenants.create_staff_invite(scope_a, venue_b.id, %{
                 "email" => unique_email(),
                 "role" => "waiter"
               })

      assert "does not exist" in errors_on(changeset).venue_id
    end

    test "get_valid_staff_invite_by_token/1 finds a pending, unexpired invite" do
      %{org: org, venue: venue} = org_fixture()
      scope = %Scope{org: org}

      {:ok, invite} =
        Tenants.create_staff_invite(scope, venue.id, %{
          "email" => unique_email(),
          "role" => "cashier"
        })

      assert %StaffInvite{id: id} = Tenants.get_valid_staff_invite_by_token(invite.token)
      assert id == invite.id
    end

    test "get_valid_staff_invite_by_token/1 returns nil for an unknown token" do
      refute Tenants.get_valid_staff_invite_by_token("does-not-exist")
    end

    test "get_valid_staff_invite_by_token/1 returns nil for an expired invite" do
      %{org: org, venue: venue} = org_fixture()
      scope = %Scope{org: org}

      {:ok, invite} =
        Tenants.create_staff_invite(scope, venue.id, %{
          "email" => unique_email(),
          "role" => "kitchen"
        })

      {:ok, invite} =
        invite
        |> Ecto.Changeset.change(expires_at: DateTime.add(DateTime.utc_now(:second), -1, :day))
        |> Repo.update()

      refute Tenants.get_valid_staff_invite_by_token(invite.token)
    end

    test "get_valid_staff_invite_by_token/1 returns nil for an already-accepted invite" do
      %{org: org, venue: venue} = org_fixture()
      scope = %Scope{org: org}

      {:ok, invite} =
        Tenants.create_staff_invite(scope, venue.id, %{
          "email" => unique_email(),
          "role" => "waiter"
        })

      {:ok, _} =
        Tenants.accept_staff_invite(invite, %{}, login_url_fun())

      refute Tenants.get_valid_staff_invite_by_token(invite.token)
    end

    test "accept_staff_invite/2 for a waiter creates a magic-link-first user + venue membership" do
      %{org: org, venue: venue} = org_fixture()
      scope = %Scope{org: org}
      email = unique_email()

      {:ok, invite} =
        Tenants.create_staff_invite(scope, venue.id, %{"email" => email, "role" => "waiter"})

      assert {:ok, %{user: user, membership: membership, invite: accepted_invite}} =
               Tenants.accept_staff_invite(invite, %{}, login_url_fun())

      assert user.email == email
      assert user.hashed_password == nil

      assert membership.org_id == org.id
      assert membership.venue_id == venue.id
      assert membership.role == :waiter

      assert accepted_invite.accepted_at != nil

      # Login instructions actually went out — otherwise this person exists
      # in the database with no way to ever authenticate.
      assert Repo.get_by(Tabletap.Accounts.UserToken, [user_id: user.id, context: "login"],
               skip_org_id: true
             )
    end

    test "accept_staff_invite/2 for a manager requires a password (design-qa.md Q47)" do
      %{org: org, venue: venue} = org_fixture()
      scope = %Scope{org: org}
      email = unique_email()

      {:ok, invite} =
        Tenants.create_staff_invite(scope, venue.id, %{"email" => email, "role" => "manager"})

      assert {:error, %Ecto.Changeset{} = changeset} =
               Tenants.accept_staff_invite(invite, %{}, login_url_fun())

      assert "can't be blank" in errors_on(changeset).password

      assert {:ok, %{user: user, membership: membership}} =
               Tenants.accept_staff_invite(
                 invite,
                 %{"password" => valid_password(), "password_confirmation" => valid_password()},
                 login_url_fun()
               )

      assert user.email == email
      assert user.hashed_password != nil
      assert membership.role == :manager
      assert membership.venue_id == venue.id

      # A password-holding manager doesn't need a magic link.
      refute Repo.get_by(Tabletap.Accounts.UserToken, [user_id: user.id, context: "login"],
               skip_org_id: true
             )
    end

    test "accept_staff_invite/2 attaches an EXISTING user to a second venue instead of failing to re-register (project-overview.md: \"the same person can be a manager at one venue and a waiter at another\")" do
      %{user: owner, org: org_a, venue: venue_a} = org_fixture()
      %{org: org_b, venue: venue_b} = org_fixture()

      # owner (of org_a) is separately invited as a waiter at org_b's venue.
      scope_b = %Scope{org: org_b}

      {:ok, invite} =
        Tenants.create_staff_invite(scope_b, venue_b.id, %{
          "email" => owner.email,
          "role" => "waiter"
        })

      assert {:ok, %{user: user, membership: membership}} =
               Tenants.accept_staff_invite(invite, %{}, login_url_fun())

      assert user.id == owner.id
      assert membership.org_id == org_b.id
      assert membership.venue_id == venue_b.id
      assert membership.role == :waiter

      # Their original owner membership at org_a is untouched.
      scope = Tenants.build_scope(user, %{})
      assert scope.org.id == org_a.id
      assert scope.venue.id == venue_a.id
      assert scope.role == :owner
    end

    test "accept_staff_invite/2 sets a password for an existing passwordless user invited as manager" do
      # A genuinely magic-link-only account (org_fixture's owner already has
      # a password, per Q47 — this needs a real waiter-shaped account).
      magic_link_user = Tabletap.AccountsFixtures.user_fixture()
      refute magic_link_user.hashed_password

      %{org: org, venue: venue} = org_fixture()
      scope = %Scope{org: org}

      {:ok, invite} =
        Tenants.create_staff_invite(scope, venue.id, %{
          "email" => magic_link_user.email,
          "role" => "manager"
        })

      assert {:error, %Ecto.Changeset{} = changeset} =
               Tenants.accept_staff_invite(invite, %{}, login_url_fun())

      assert "can't be blank" in errors_on(changeset).password

      assert {:ok, %{user: user, membership: membership}} =
               Tenants.accept_staff_invite(
                 invite,
                 %{"password" => valid_password(), "password_confirmation" => valid_password()},
                 login_url_fun()
               )

      assert user.id == magic_link_user.id
      assert user.hashed_password != nil
      assert membership.role == :manager
    end
  end

  describe "deny-by-default for a scope with no resolved org" do
    test "list_venues/1 returns an empty list, not a crash" do
      assert Tenants.list_venues(%Scope{org: nil}) == []
    end

    test "switch_venue/2 returns :not_found, not a crash" do
      assert {:error, :not_found} = Tenants.switch_venue(%Scope{org: nil}, "any-id")
    end

    test "create_staff_invite/3 returns :not_found, not a crash" do
      assert {:error, :not_found} =
               Tenants.create_staff_invite(%Scope{org: nil}, "any-id", %{})
    end
  end

  describe "business_date/2 (design-qa.md Q20)" do
    test "before the cutoff belongs to yesterday's business day" do
      venue = %Venue{timezone: "Africa/Mogadishu", business_day_cutoff: ~T[04:00:00]}
      # 01:00 in Africa/Mogadishu (UTC+3) == 22:00 UTC the day before.
      datetime = DateTime.new!(~D[2026-03-05], ~T[22:00:00], "Etc/UTC")

      assert Tenants.business_date(venue, datetime) == ~D[2026-03-05]
    end

    test "at or after the cutoff belongs to today" do
      venue = %Venue{timezone: "Africa/Mogadishu", business_day_cutoff: ~T[04:00:00]}
      # 10:00 in Africa/Mogadishu (UTC+3) == 07:00 UTC.
      datetime = DateTime.new!(~D[2026-03-06], ~T[07:00:00], "Etc/UTC")

      assert Tenants.business_date(venue, datetime) == ~D[2026-03-06]
    end

    test "defaults to now when no datetime is given" do
      venue = %Venue{timezone: "Etc/UTC", business_day_cutoff: ~T[00:00:00]}

      assert Tenants.business_date(venue) == Date.utc_today()
    end
  end

  describe "get_venue_by_slug/1" do
    test "finds an active venue by slug, org preloaded" do
      %{org: org, venue: venue} = org_fixture()

      found = Tenants.get_venue_by_slug(venue.slug)

      assert found.id == venue.id
      assert found.org.id == org.id
    end

    test "returns nil for an archived venue" do
      %{venue: venue} = org_fixture()

      {:ok, venue} =
        venue |> Ecto.Changeset.change(archived_at: DateTime.utc_now(:second)) |> Repo.update()

      assert Tenants.get_venue_by_slug(venue.slug) == nil
    end

    test "returns nil for an unknown slug" do
      assert Tenants.get_venue_by_slug("does-not-exist") == nil
    end
  end

  defp login_url_fun, do: fn token -> "https://example.com/log-in/#{token}" end
end
