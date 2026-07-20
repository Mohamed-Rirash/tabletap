defmodule Tabletap.TenantsTest do
  use Tabletap.DataCase, async: true

  alias Tabletap.Accounts.Scope
  alias Tabletap.Ordering.Cart
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

    test "the Venue schema itself rejects an unsupported currency or timezone" do
      # Schema-level backstop for Q53: a caller that bypasses resolve_city/1
      # (a future API endpoint, a script) still can't create a venue with an
      # arbitrary currency — the changeset refuses it, not just the form.
      changeset =
        Venue.registration_changeset(%Venue{}, %{
          "name" => "Rogue Venue",
          "currency" => "KES",
          "timezone" => "Africa/Nairobi"
        })

      refute changeset.valid?
      assert "is invalid" in errors_on(changeset).currency
      assert "is invalid" in errors_on(changeset).timezone
    end

    test "every launch city resolves to a currency/timezone the Venue schema accepts" do
      # Drift guard: adding a city to Tenants.city_options/0 with a currency
      # or timezone missing from Venue's supported lists must fail here, not
      # at the first real signup.
      for {_name, currency, timezone} <- Tenants.city_options() do
        assert currency in Venue.supported_currencies()
        assert timezone in Venue.supported_timezones()
      end
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

  describe "create_venue/2" do
    setup do
      %{org: org, venue: venue, membership: owner} = org_fixture()
      Repo.put_org_id(org.id)

      %{
        org: org,
        venue: venue,
        scope: %Scope{org: org, venue: venue, role: :owner, membership: owner}
      }
    end

    test "adds a second venue while under the plan's cap", %{org: org, scope: scope} do
      org = org |> Ecto.Changeset.change(plan: :pro) |> Repo.update!()
      scope = %{scope | org: org}

      assert {:ok, %Venue{} = venue} =
               Tenants.create_venue(scope, %{"name" => "Second Spot", "city" => "Mogadishu"})

      assert venue.org_id == org.id
      assert venue.currency == "USD"
      assert Enum.map(Tenants.list_venues(scope), & &1.id) |> Enum.member?(venue.id)
    end

    test "blocked once venue count meets the plan's cap (Essentials/Growth cap at 1)", %{
      scope: scope
    } do
      assert {:error, :venue_cap_reached} =
               Tenants.create_venue(scope, %{"name" => "Second Spot", "city" => "Mogadishu"})
    end

    test "rejects an unrecognized city, same as org signup", %{org: org, scope: scope} do
      org = org |> Ecto.Changeset.change(plan: :pro) |> Repo.update!()
      scope = %{scope | org: org}

      assert {:error, %Ecto.Changeset{} = changeset} =
               Tenants.create_venue(scope, %{"name" => "Second Spot", "city" => "Nairobi"})

      assert "is not a supported launch city" in errors_on(changeset).city
    end
  end

  describe "initiate_offboarding/1" do
    test "sets offboarding_requested_at once, idempotently" do
      %{org: org, venue: venue, membership: owner} = org_fixture()
      Repo.put_org_id(org.id)
      scope = %Scope{org: org, venue: venue, role: :owner, membership: owner}

      assert {:ok, org} = Tenants.initiate_offboarding(scope)
      assert org.offboarding_requested_at != nil
      first_timestamp = org.offboarding_requested_at

      assert {:ok, org_again} = Tenants.initiate_offboarding(%{scope | org: org})
      assert org_again.offboarding_requested_at == first_timestamp
    end
  end

  describe "export_org_data/1" do
    test "returns menu, orders, and ingredients CSVs reconciling real data" do
      %{org: org, venue: venue, membership: owner} = org_fixture()
      Repo.put_org_id(org.id)
      scope = %Scope{org: org, venue: venue, role: :owner, membership: owner}

      {:ok, category} = Tabletap.Catalog.create_category(scope, %{"name" => "Drinks"})

      {:ok, item} =
        Tabletap.Catalog.create_item(scope, category, %{
          "name" => "Latte",
          "price" => Money.new!(:USD, "3.50")
        })

      {:ok, ingredient} =
        Tabletap.Inventory.create_ingredient(scope, %{
          "name" => "Milk",
          "unit" => "ml",
          "cost_per_unit" => Money.new!(:USD, "0.01")
        })

      %{membership: cashier} = cashier_fixture(org, venue)
      cashier_scope = %{scope | role: :cashier, membership: cashier}
      token = Cart.generate_guest_token()
      {:ok, cart} = Tabletap.Ordering.add_to_cart(cashier_scope, token, nil, item, [], 1, nil)
      {:ok, order} = Tabletap.Ordering.checkout(cashier_scope, cart)
      {:ok, _} = Tabletap.Payments.settle_cash_now(cashier_scope, order, cashier)

      files = Tenants.export_org_data(scope)

      assert files["menu.csv"] =~ venue.name
      assert files["menu.csv"] =~ item.name
      assert files["orders.csv"] =~ to_string(order.number)
      assert files["ingredients.csv"] =~ ingredient.name
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

  describe "Busy Mode (design-qa.md Q2)" do
    setup do
      %{org: org, venue: venue} = org_fixture()
      Repo.put_org_id(org.id)
      %{scope: %Scope{org: org, venue: venue}, venue: venue}
    end

    test "pause_ordering/3 pauses checkout for N minutes", %{scope: scope, venue: venue} do
      {:ok, venue} = Tenants.pause_ordering(scope, venue, 20)

      assert Venue.paused?(venue)
      assert DateTime.compare(venue.ordering_paused_until, DateTime.utc_now()) == :gt
    end

    test "pause_ordering/3 with :indefinite uses the far-future sentinel (\"until reopened\")", %{
      scope: scope,
      venue: venue
    } do
      {:ok, venue} = Tenants.pause_ordering(scope, venue, :indefinite)

      assert venue.ordering_paused_until == Venue.indefinite_pause_sentinel()
      assert Venue.paused?(venue)
    end

    test "resume_ordering/2 clears the pause", %{scope: scope, venue: venue} do
      {:ok, venue} = Tenants.pause_ordering(scope, venue, 20)
      {:ok, venue} = Tenants.resume_ordering(scope, venue)

      refute Venue.paused?(venue)
      assert venue.ordering_paused_until == nil
    end

    test "set_eta_inflation/3 sets the ETA multiplier", %{scope: scope, venue: venue} do
      {:ok, venue} = Tenants.set_eta_inflation(scope, venue, Decimal.new("1.5"))

      assert Decimal.equal?(venue.eta_inflation_factor, Decimal.new("1.5"))
    end

    test "set_eta_inflation/3 rejects a factor below 1", %{scope: scope, venue: venue} do
      assert {:error, changeset} = Tenants.set_eta_inflation(scope, venue, Decimal.new("0.5"))
      assert "must be greater than or equal to 1" in errors_on(changeset).eta_inflation_factor
    end
  end

  describe "venue_open?/2 (design-qa.md Q2 opening-hours gate)" do
    test "nil opening_hours means always open (no manager-facing editor ships in this feature)" do
      assert Tenants.venue_open?(%Venue{opening_hours: nil, timezone: "Etc/UTC"})
    end

    test "open during a configured range on the matching weekday" do
      hours = %{"monday" => [%{"open" => "08:00", "close" => "22:00"}]}
      venue = %Venue{opening_hours: hours, timezone: "Etc/UTC"}
      # 2026-03-02 is a Monday.
      datetime = DateTime.new!(~D[2026-03-02], ~T[10:00:00], "Etc/UTC")

      assert Tenants.venue_open?(venue, datetime)
    end

    test "closed outside the configured range on the matching weekday" do
      hours = %{"monday" => [%{"open" => "08:00", "close" => "22:00"}]}
      venue = %Venue{opening_hours: hours, timezone: "Etc/UTC"}
      datetime = DateTime.new!(~D[2026-03-02], ~T[23:00:00], "Etc/UTC")

      refute Tenants.venue_open?(venue, datetime)
    end

    test "closed on a day with no configured ranges at all" do
      hours = %{"monday" => [%{"open" => "08:00", "close" => "22:00"}]}
      venue = %Venue{opening_hours: hours, timezone: "Etc/UTC"}
      # 2026-03-03 is a Tuesday — no entry for it.
      datetime = DateTime.new!(~D[2026-03-03], ~T[10:00:00], "Etc/UTC")

      refute Tenants.venue_open?(venue, datetime)
    end

    test "the open boundary itself counts as open" do
      hours = %{"monday" => [%{"open" => "08:00", "close" => "22:00"}]}
      venue = %Venue{opening_hours: hours, timezone: "Etc/UTC"}
      datetime = DateTime.new!(~D[2026-03-02], ~T[08:00:00], "Etc/UTC")

      assert Tenants.venue_open?(venue, datetime)
    end

    test "the close boundary itself counts as closed" do
      hours = %{"monday" => [%{"open" => "08:00", "close" => "22:00"}]}
      venue = %Venue{opening_hours: hours, timezone: "Etc/UTC"}
      datetime = DateTime.new!(~D[2026-03-02], ~T[22:00:00], "Etc/UTC")

      refute Tenants.venue_open?(venue, datetime)
    end

    test "a split-hours day (lunch/dinner) is closed in the gap between ranges" do
      hours = %{
        "monday" => [
          %{"open" => "08:00", "close" => "14:00"},
          %{"open" => "18:00", "close" => "22:00"}
        ]
      }

      venue = %Venue{opening_hours: hours, timezone: "Etc/UTC"}

      assert Tenants.venue_open?(venue, DateTime.new!(~D[2026-03-02], ~T[12:00:00], "Etc/UTC"))
      refute Tenants.venue_open?(venue, DateTime.new!(~D[2026-03-02], ~T[16:00:00], "Etc/UTC"))
      assert Tenants.venue_open?(venue, DateTime.new!(~D[2026-03-02], ~T[20:00:00], "Etc/UTC"))
    end

    test "a date-specific override takes precedence over the weekday's normal hours" do
      hours = %{
        "monday" => [%{"open" => "08:00", "close" => "22:00"}],
        "overrides" => %{"2026-03-02" => []}
      }

      venue = %Venue{opening_hours: hours, timezone: "Etc/UTC"}
      datetime = DateTime.new!(~D[2026-03-02], ~T[10:00:00], "Etc/UTC")

      refute Tenants.venue_open?(venue, datetime)
    end

    test "weekday resolution uses the venue's local date, not UTC's" do
      # 23:30 UTC on Sunday 2026-03-01 is already 02:30 Monday in
      # Mogadishu (UTC+3) — the Monday-only range should apply, not
      # Sunday's absence from the schedule.
      hours = %{"monday" => [%{"open" => "00:00", "close" => "23:59:59"}]}
      venue = %Venue{opening_hours: hours, timezone: "Africa/Mogadishu"}
      datetime = DateTime.new!(~D[2026-03-01], ~T[23:30:00], "Etc/UTC")

      assert Tenants.venue_open?(venue, datetime)
    end
  end

  defp login_url_fun, do: fn token -> "https://example.com/log-in/#{token}" end
end
