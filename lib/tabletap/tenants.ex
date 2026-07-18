defmodule Tabletap.Tenants do
  @moduledoc """
  Organizations, venues, tables, memberships, staff invites — the tenancy
  core (architecture.md "Multi-Tenancy", build-plan.md Feature 03/06).
  Tables live here (rather than in `Catalog` or a separate context)
  because their public `/t/:qr_token` resolution needs `skip_org_id: true`,
  which is allowed only in this context — and they're venue child-entities
  like memberships.

  Bootstrapping/resolution functions (`create_org_with_owner/1`,
  `build_scope/2`, invite lookup/acceptance) run before a tenant scope
  exists and use `skip_org_id: true` — one of the few contexts allowed to
  (code-standards.md "Tenancy Rules"). Everything else takes `%Scope{}`
  first and trusts `Tabletap.Repo.put_org_id/1` having already been set for
  the current process (done once per request by `TabletapWeb.UserAuth`).
  """

  import Ecto.Query, warn: false

  alias Tabletap.Accounts
  alias Tabletap.Accounts.{Scope, User}
  alias Tabletap.Repo
  alias Tabletap.Tenants.{Membership, Org, StaffInvite, Table, Venue}

  ## Launch markets (design-qa.md Q57/Q60/Q61) — the signup form offers a
  ## city picker instead of raw currency/timezone entry.

  @city_options [
    {"Hargeisa", "USD", "Africa/Mogadishu"},
    {"Mogadishu", "USD", "Africa/Mogadishu"},
    {"Jigjiga", "ETB", "Africa/Addis_Ababa"}
  ]

  @doc "The launch-market cities offered on the signup form, with their currency/timezone."
  def city_options, do: @city_options

  @doc """
  Resolves `datetime` (default now) to the venue's current business date —
  the one shared implementation every "today" concept uses (daily limits,
  Z-report, rollups, order numbers), never ad-hoc date math
  (code-standards.md; design-qa.md Q20/Q39).

  Business days run cutoff-to-cutoff in the venue's own timezone: before
  `business_day_cutoff` (default 04:00), `datetime` still belongs to
  yesterday's business day.
  """
  def business_date(%Venue{} = venue, %DateTime{} = datetime \\ DateTime.utc_now()) do
    local = DateTime.shift_zone!(datetime, venue.timezone)

    if Time.compare(DateTime.to_time(local), venue.business_day_cutoff) == :lt do
      Date.add(DateTime.to_date(local), -1)
    else
      DateTime.to_date(local)
    end
  end

  @doc """
  Resolves a picked city name to `{:ok, {currency, timezone}}`, or `:error`
  if `city_name` isn't one of `city_options/0`'s names. Never silently
  defaults — currency locks permanently after a venue's first order
  (design-qa.md Q53), so a caller that bypasses the signup form's own
  client-side validation (a future API endpoint, a script) must get a loud
  failure here, not a wrong-but-valid venue.
  """
  def resolve_city(city_name) do
    case Enum.find(@city_options, fn {name, _, _} -> name == city_name end) do
      {_name, currency, timezone} -> {:ok, {currency, timezone}}
      nil -> :error
    end
  end

  ## Org signup

  @doc """
  Creates a brand-new org, its first venue, an owner account (password
  required — design-qa.md Q47), and the owner's org-wide membership, all in
  one transaction. This is the only way an org comes into existence — there
  is no bare "create an org" without an owner and a first venue
  (build-plan.md Feature 03: "Org signup flow: create org → first venue →
  owner membership").

  `attrs` — `email`, `password`, `password_confirmation`, `business_name`,
  `city` (one of `city_options/0`'s names). Returns `{:error, changeset}`
  with an error on `:city` if `city` isn't recognized — the signup form
  validates this client-side already, so this is a defensive boundary
  check for any other caller, not a path a real signup should ever hit.
  """
  def create_org_with_owner(attrs) do
    case resolve_city(attrs["city"] || attrs[:city]) do
      {:ok, {currency, timezone}} -> do_create_org_with_owner(attrs, currency, timezone)
      :error -> {:error, invalid_city_changeset(attrs)}
    end
  end

  defp invalid_city_changeset(attrs) do
    %Org{}
    |> Org.registration_changeset(%{"name" => business_name(attrs)})
    |> Ecto.Changeset.add_error(:city, "is not a supported launch city")
  end

  defp do_create_org_with_owner(attrs, currency, timezone) do
    Repo.transact(fn ->
      with {:ok, user} <- Accounts.register_owner(attrs),
           {:ok, org} <-
             %Org{}
             |> Org.registration_changeset(%{"name" => business_name(attrs)})
             |> Repo.insert(),
           {:ok, venue} <-
             %Venue{org_id: org.id}
             |> Venue.registration_changeset(%{
               "name" => business_name(attrs),
               "currency" => currency,
               "timezone" => timezone
             })
             |> Repo.insert(),
           {:ok, membership} <-
             %Membership{}
             |> Membership.changeset(%{
               org_id: org.id,
               venue_id: nil,
               user_id: user.id,
               role: :owner
             })
             |> Repo.insert() do
        {:ok, %{user: user, org: org, venue: venue, membership: membership}}
      end
    end)
  end

  defp business_name(attrs), do: attrs["business_name"] || attrs[:business_name]

  ## Scope resolution — called once per request by TabletapWeb.UserAuth

  @doc """
  Builds the `%Scope{}` for an authenticated user: resolves which
  membership is "current" (session-remembered, else the earliest), and
  which venue (the membership's own venue for staff; the
  session-remembered or first venue of the org for an owner, whose
  membership is org-wide). A user with no memberships yet (e.g. a future
  customer account, Feature 16) gets a scope with `org`/`venue`/`role` all
  `nil` — logged in, but authorized for nothing staff-side, which is
  correct deny-by-default behavior, not a bug.
  """
  def build_scope(nil, _session), do: Scope.for_user(nil)

  def build_scope(user, session) do
    memberships = list_active_memberships_for_user(user)

    membership =
      pick_by_id(memberships, session["current_membership_id"]) || List.first(memberships)

    case membership do
      nil ->
        %Scope{user: user}

      %Membership{venue_id: nil} = m ->
        # Owner — org-wide membership, but the dashboard still needs a
        # "current" venue to display.
        org_venues = list_venues_for_org(m.org_id)
        venue = pick_by_id(org_venues, session["current_venue_id"]) || List.first(org_venues)

        %Scope{user: user, org: m.org, venue: venue, membership: m, role: m.role}

      %Membership{} = m ->
        %Scope{user: user, org: m.org, venue: m.venue, membership: m, role: m.role}
    end
  end

  defp list_active_memberships_for_user(user) do
    Repo.all(
      from(m in Membership,
        where: m.user_id == ^user.id and m.active == true,
        order_by: [asc: m.inserted_at],
        preload: [:org, :venue]
      ),
      skip_org_id: true
    )
  end

  defp list_venues_for_org(org_id) do
    Repo.all(
      from(v in Venue,
        where: v.org_id == ^org_id and is_nil(v.archived_at),
        order_by: v.inserted_at
      ),
      skip_org_id: true
    )
  end

  defp pick_by_id(_list, nil), do: nil
  defp pick_by_id(list, id), do: Enum.find(list, &(&1.id == id))

  ## Public/customer resolution — no tenant scope exists yet (skip_org_id
  ## is allowed here, same as build_scope/2 above); the caller is
  ## responsible for calling Repo.put_org_id/1 with the returned venue's
  ## org_id afterwards, exactly like UserAuth does for staff requests
  ## (library-docs.md "Customer/public paths build an unauthenticated
  ## scope from the QR-resolved venue").

  @doc """
  Looks up an active venue by its slug, org preloaded. Returns `nil` for
  an archived or unknown slug — never a raw crash on a bad/rotated link.
  """
  def get_venue_by_slug(slug) do
    Repo.one(
      from(v in Venue, where: v.slug == ^slug and is_nil(v.archived_at), preload: [:org]),
      skip_org_id: true
    )
  end

  @doc """
  Resolves a scanned `/t/:qr_token` to its table, venue + org preloaded —
  the public QR entry point (build-plan.md Feature 06). Same pre-auth,
  skip_org_id shape as `get_venue_by_slug/1`: no tenant scope exists yet,
  so the caller calls `Repo.put_org_id/1` with the returned table's
  `org_id` afterwards.

  Returns `nil` for an unknown, rotated (old token), archived, or
  deactivated table — a stale or forged QR gets an honest "not found",
  never a crash or a leak (design-qa.md Q7).
  """
  def get_table_by_qr_token(qr_token) do
    Repo.one(
      from(t in Table,
        where: t.qr_token == ^qr_token and t.active == true and is_nil(t.archived_at),
        preload: [venue: :org]
      ),
      skip_org_id: true
    )
  end

  @doc """
  Every org id — the enumeration entry point for background jobs that
  must sweep across every tenant (e.g.
  `Ordering.Workers.SweepAbandonedCarts`, build-plan.md Feature 07).
  `skip_org_id: true` is allowed here (Tenants is on the exception list);
  the caller loops this list and calls `Repo.put_org_id/1` once per org
  before running its own normal tenant-scoped query — a raw cross-tenant
  query anywhere else in the codebase is still forbidden
  (code-standards.md "Tenancy Rules"). Not paginated: orgs are small in
  count relative to their child rows even at real scale.
  """
  def list_org_ids do
    Repo.all(from(o in Org, select: o.id), skip_org_id: true)
  end

  @doc """
  Resolves a bare `/orders/:guest_token` to its most recent order across
  every venue/org — the public, pre-scope entry point for the order
  tracker (build-plan.md Feature 08). Same shape as `get_venue_by_slug/1`/
  `get_table_by_qr_token/1`: no tenant scope exists yet, so the caller
  calls `Repo.put_org_id/1` with the returned order's `org_id` afterwards.

  A deliberate, narrow exception to "contexts own their tables" —
  `orders` otherwise belongs entirely to `Ordering`. The alternative
  (looping every org via `list_org_ids/0`, `Ordering`'s own sanctioned
  cross-tenant pattern for background jobs) would turn every tracker
  page load into an O(orgs) scan; that's an acceptable cost for an
  hourly sweep, not for a latency-sensitive customer-facing page.
  Tenants is this codebase's established home for resolving an opaque
  public token before any scope exists, so the same shape is extended
  here rather than inventing a second mechanism.

  A `guest_token` is a bare cookie value with no venue scoping of its
  own — the same browser could in principle hold orders at more than
  one venue under one token, so "most recent by `inserted_at`" is a
  pragmatic, not a strict, guarantee. Returns `nil` if no order has ever
  used this token.
  """
  def get_order_by_guest_token(guest_token) do
    Repo.one(
      from(o in Tabletap.Ordering.Order,
        where: o.guest_token == ^guest_token,
        order_by: [desc: o.inserted_at],
        limit: 1,
        preload: [venue: :org]
      ),
      skip_org_id: true
    )
  end

  @doc """
  Resolves a payment by id with no scope — the pre-scope entry point for
  the WaafiPay webhook controller (build-plan.md Feature 09), which
  receives a callback identified only by the `requestId` WaafiPay echoes
  back (our own `payment.id`, sent at charge time — library-docs.md).
  Same narrow `skip_org_id: true` exception as `get_order_by_guest_token/1`
  for the identical reason: no scope exists yet to enforce. The caller
  calls `Repo.put_org_id/1` off the preloaded order's `org_id` afterward.
  """
  def get_payment_by_id(payment_id) do
    Repo.one(
      from(p in Tabletap.Payments.Payment, where: p.id == ^payment_id, preload: :order),
      skip_org_id: true
    )
  end

  ## Venues (tenant-scoped — relies on Repo.put_org_id already being set)

  @doc "Lists the current org's active venues, for the venue switcher."
  def list_venues(%Scope{org: %Org{}} = scope) do
    Repo.all(
      from(v in Venue,
        where: v.org_id == ^scope.org.id and is_nil(v.archived_at),
        order_by: v.inserted_at
      )
    )
  end

  # A scope with no resolved org (a bare authenticated user with no staff
  # membership) sees no venues — deny-by-default, not a FunctionClauseError.
  # Every caller today is already behind ScopeHooks.require_manager, which
  # guarantees org is set, but this is cheap insurance against a future
  # route that isn't.
  def list_venues(%Scope{org: nil}), do: []

  @doc """
  Validates `venue_id` belongs to the scope's org before it's written to the
  session as the "current venue" — the venue switcher's authorization
  check.
  """
  def switch_venue(%Scope{org: %Org{}} = scope, venue_id) do
    # Deliberately skip_org_id: true — this must be able to find a venue
    # belonging to a DIFFERENT org (that's exactly the case being guarded
    # against) and compare org_id explicitly, rather than have the
    # tenant-scoped query silently filter it to not-found either way.
    # archived_at is checked here too, matching list_venues/1's filter —
    # otherwise a stale link could switch to a venue the switcher itself
    # would never list.
    case Repo.get(Venue, venue_id, skip_org_id: true) do
      %Venue{org_id: org_id, archived_at: nil} = venue when org_id == scope.org.id ->
        {:ok, venue}

      _ ->
        {:error, :not_found}
    end
  end

  # POST /venues/switch only requires an authenticated session
  # (require_authenticated_user), not a resolved org (that's require_manager,
  # which /dashboard has but this action doesn't) — a bare user hitting it
  # gets the same "not found" any other invalid venue_id would, not a crash.
  def switch_venue(%Scope{org: nil}, _venue_id), do: {:error, :not_found}

  ## Tables (venue floor — build-plan.md Feature 06). Venue-scoped like
  ## Catalog: `Repo`'s org filter isn't enough on its own since an org can
  ## have more than one venue. The public scan path resolves through
  ## `get_table_by_qr_token/1` above instead.

  @doc "A venue's non-archived tables, in creation order."
  def list_tables(%Scope{venue: venue}) do
    Repo.all(
      from(t in Table,
        where: t.venue_id == ^venue.id and is_nil(t.archived_at),
        order_by: t.inserted_at
      )
    )
  end

  @doc "A single non-archived table in the scope's venue, or nil (no cross-tenant leak via a guessed id)."
  def get_table(%Scope{venue: venue}, id) do
    Repo.one(
      from(t in Table,
        where: t.id == ^id and t.venue_id == ^venue.id and is_nil(t.archived_at)
      )
    )
  end

  @doc "Creates a table in the scope's venue with a fresh opaque QR token."
  def create_table(%Scope{org: org, venue: venue}, attrs) do
    %Table{org_id: org.id, venue_id: venue.id, qr_token: Table.generate_qr_token()}
    |> Table.creation_changeset(attrs)
    |> Repo.insert()
  end

  def update_table(%Scope{}, %Table{} = table, attrs) do
    table |> Table.update_changeset(attrs) |> Repo.update()
  end

  @doc "Rotates a table's QR token — the old printed code stops resolving (design-qa.md Q7)."
  def rotate_qr_token(%Scope{}, %Table{} = table) do
    table |> Table.rotate_changeset() |> Repo.update()
  end

  @doc "Archives a table — hidden from the floor/pickers, intact in every order and FK (design-qa.md Q41)."
  def archive_table(%Scope{}, %Table{} = table) do
    table |> Table.archive_changeset() |> Repo.update()
  end

  ## Busy Mode (build-plan.md Feature 08, design-qa.md Q2) — venue-level
  ## checkout throttle. `venues` is this context's table; `Ordering`'s
  ## checkout gate reads `scope.venue.ordering_paused_until`/
  ## `eta_inflation_factor` directly off the already-loaded struct rather
  ## than calling back into Tenants for a read.

  @doc "Pause: snoozes new checkout for 20/40 minutes, or `:indefinite` (\"until reopened\")."
  def pause_ordering(%Scope{}, %Venue{} = venue, minutes_or_indefinite) do
    venue |> Venue.pause_changeset(minutes_or_indefinite) |> Repo.update()
  end

  def resume_ordering(%Scope{}, %Venue{} = venue) do
    venue |> Venue.resume_changeset() |> Repo.update()
  end

  @doc "Slow: inflates the displayed ETA by `factor` (>= 1) without pausing orders outright."
  def set_eta_inflation(%Scope{}, %Venue{} = venue, factor) do
    venue |> Venue.eta_inflation_changeset(factor) |> Repo.update()
  end

  @doc """
  Whether `venue` is open at `datetime` (default now), per its
  `opening_hours`. `nil` (no hours ever configured — no editor UI ships
  in this feature) means always open, a safe default so this gate can
  never accidentally lock a venue out of ordering.
  """
  def venue_open?(venue, datetime \\ DateTime.utc_now())
  def venue_open?(%Venue{opening_hours: nil}, _datetime), do: true

  def venue_open?(%Venue{opening_hours: hours} = venue, datetime) do
    local = DateTime.shift_zone!(datetime, venue.timezone)
    date_key = local |> DateTime.to_date() |> Date.to_iso8601()
    ranges = get_in(hours, ["overrides", date_key]) || Map.get(hours, weekday_key(local))
    time = DateTime.to_time(local)

    Enum.any?(ranges || [], fn %{"open" => open, "close" => close} ->
      Time.compare(time, parse_hours_time!(open)) != :lt and
        Time.compare(time, parse_hours_time!(close)) == :lt
    end)
  end

  @weekday_keys {"monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday"}
  defp weekday_key(%DateTime{} = local), do: elem(@weekday_keys, Date.day_of_week(local) - 1)

  # `opening_hours` stores "HH:MM" (architecture.md's own documented
  # shape) — `Time.from_iso8601!/1` alone rejects that (strict ISO 8601
  # requires seconds), so a real venue's configured hours would raise
  # here. Padding to "HH:MM:SS" before parsing accepts both forms.
  defp parse_hours_time!(time_string) do
    case String.split(time_string, ":") do
      [_hour, _minute] -> Time.from_iso8601!(time_string <> ":00")
      _full -> Time.from_iso8601!(time_string)
    end
  end

  ## Payment credentials (build-plan.md Feature 09, design-qa.md Q57/Q58)
  ## — `venues` is this context's table; `Payments` reads
  ## `scope.venue.waafipay_*`/`charges_enabled` directly off the
  ## already-loaded struct, same read-through-scope pattern as Busy Mode.

  @doc "Saves (or replaces) the venue's WaafiPay merchant credentials — always unverified until `mark_charges_enabled/2` runs."
  def update_waafipay_credentials(%Scope{}, %Venue{} = venue, attrs) do
    venue |> Venue.waafipay_credentials_changeset(attrs) |> Repo.update()
  end

  @doc "Flips `charges_enabled` true — only `Payments.verify_credentials/2`, after a real successful lookup, should call this."
  def mark_charges_enabled(%Venue{} = venue) do
    venue |> Venue.verified_changeset() |> Repo.update()
  end

  @doc "Owner toggle for design-qa.md Q3's pay-at-counter option (build-plan.md Feature 15) — independent of wallet `charges_enabled`, a venue can take counter cash with no wallet credentials at all."
  def set_pay_at_counter_enabled(%Scope{}, %Venue{} = venue, enabled?) do
    venue |> Venue.pay_at_counter_changeset(enabled?) |> Repo.update()
  end

  @doc """
  Memberships by id, user preloaded — a display-name lookup for surfaces
  that only carry membership ids (the Z-report's per-cashier cash
  counts, build-plan.md Feature 15). Two queries, not `preload: :user`:
  `users` has no `org_id` column, so a normal tenant-scoped preload's
  inner query would hit it too (`Repo.prepare_query/3` injects `org_id`
  into every query it runs, preloads included) and raise — the `User`
  lookup needs its own explicit `skip_org_id: true`, same as `Accounts`
  does everywhere else it touches `users` directly.
  """
  def list_memberships(%Scope{}, ids) when is_list(ids) do
    memberships = Repo.all(from(m in Membership, where: m.id in ^ids))
    user_ids = Enum.map(memberships, & &1.user_id)

    users =
      Repo.all(from(u in User, where: u.id in ^user_ids), skip_org_id: true)
      |> Map.new(&{&1.id, &1})

    Enum.map(memberships, &%{&1 | user: Map.fetch!(users, &1.user_id)})
  end

  ## Staff invites (tenant-scoped creation; token lookup/acceptance are
  ## public — skip_org_id, since no scope exists yet for a brand-new hire)

  @doc "Creates a staff invite for a venue in the current org (manager/owner action)."
  def create_staff_invite(%Scope{org: %Org{}} = scope, venue_id, attrs) do
    # Normalize to string keys before merging — Ecto.Changeset.cast/3
    # rejects a map with mixed atom/string keys, and callers (LiveView
    # params, tests, a future API) may hand either.
    attrs =
      attrs
      |> Enum.into(%{}, fn {k, v} -> {to_string(k), v} end)
      |> Map.merge(%{"org_id" => scope.org.id, "venue_id" => venue_id})

    %StaffInvite{}
    |> StaffInvite.changeset(attrs)
    |> Repo.insert()
  end

  # Same deny-by-default reasoning as list_venues/1 and switch_venue/2 —
  # no route calls this without a resolved org today, but it isn't wired
  # to one yet either, so there's nothing enforcing that stays true.
  def create_staff_invite(%Scope{org: nil}, _venue_id, _attrs), do: {:error, :not_found}

  @doc "Looks up a pending, unexpired invite by its token — public, pre-auth."
  def get_valid_staff_invite_by_token(token) do
    now = DateTime.utc_now(:second)

    Repo.one(
      from(i in StaffInvite,
        where: i.token == ^token and is_nil(i.accepted_at) and i.expires_at > ^now,
        preload: [:org, :venue]
      ),
      skip_org_id: true
    )
  end

  @doc """
  Accepts a staff invite: finds-or-creates the user and their venue
  membership in one transaction, then marks the invite accepted.

  Handles the case project-overview.md documents explicitly — "the same
  person can be a manager at one venue and a waiter at another" — by
  looking the email up first: an existing user just gets a new membership,
  never a failed re-registration. Manager role requires a password (Q47):
  a brand-new manager gets it via the normal password-required changeset;
  an *existing* passwordless user accepting a manager invite is required
  to set one right here, since they're being handed the one role that
  can't be locked out by an email delay. Waiter/cashier/kitchen stay
  magic-link-first — `magic_link_url_fun` (same shape as
  `Accounts.deliver_login_instructions/2` expects) is used to send them a
  login link once the membership is committed; manager never needs one
  (they either just set a password or already have one).
  """
  def accept_staff_invite(%StaffInvite{} = invite, user_attrs, magic_link_url_fun)
      when is_function(magic_link_url_fun, 1) do
    result =
      Repo.transact(fn ->
        with {:ok, user} <- find_or_register_invited_user(invite, user_attrs),
             {:ok, membership} <-
               %Membership{}
               |> Membership.changeset(%{
                 org_id: invite.org_id,
                 venue_id: invite.venue_id,
                 user_id: user.id,
                 role: invite.role
               })
               |> Repo.insert(),
             {:ok, updated_invite} <-
               invite
               |> Ecto.Changeset.change(accepted_at: DateTime.utc_now(:second))
               |> Repo.update() do
          {:ok, %{user: user, membership: membership, invite: updated_invite}}
        end
      end)

    with {:ok, %{user: user}} <- result do
      maybe_deliver_login_instructions(invite.role, user, magic_link_url_fun)
    end

    result
  end

  defp find_or_register_invited_user(%StaffInvite{role: :manager} = invite, user_attrs) do
    case Accounts.get_user_by_email(invite.email) do
      nil ->
        Accounts.register_owner(Map.put(user_attrs, "email", invite.email))

      %User{hashed_password: nil} = user ->
        # Existing magic-link-only account being promoted to a
        # password-required role (Q47) — set the password now, not later.
        Accounts.update_user_password(user, user_attrs)
        |> case do
          {:ok, {updated_user, _expired_tokens}} -> {:ok, updated_user}
          {:error, _changeset} = error -> error
        end

      %User{} = user ->
        {:ok, user}
    end
  end

  defp find_or_register_invited_user(%StaffInvite{} = invite, user_attrs) do
    case Accounts.get_user_by_email(invite.email) do
      nil -> Accounts.register_user(Map.put(user_attrs, "email", invite.email))
      %User{} = user -> {:ok, user}
    end
  end

  defp maybe_deliver_login_instructions(:manager, _user, _magic_link_url_fun), do: :ok

  defp maybe_deliver_login_instructions(_role, user, magic_link_url_fun) do
    Accounts.deliver_login_instructions(user, magic_link_url_fun)
  end
end
