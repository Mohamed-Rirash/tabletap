# Library Docs

Project-specific usage patterns for every important dependency in TableTap. Read the relevant section before implementing any feature that touches these libraries.

---

## Authority Order

```
Official hexdocs for the installed version → This file (project rules) → General training knowledge
```

Elixir libraries move; `ex_money` in particular has had breaking major versions. When in doubt, check `mix hex.info <pkg>` and the hexdocs for the version in `mix.lock`. Never rely on memory alone for exact function signatures. For WaafiPay there is no hex package — the research note (`context/research/somalia-payments-waafipay-zaad.md`) and the live WaafiPay docs are the authority.

---

## Ecto — Tenant-Enforcing Repo

The core safety mechanism. From the official Ecto multi-tenancy-with-foreign-keys guide, adapted:

```elixir
# lib/tabletap/repo.ex
defmodule Tabletap.Repo do
  use Ecto.Repo, otp_app: :tabletap, adapter: Ecto.Adapters.Postgres

  require Ecto.Query

  @tenant_key {__MODULE__, :org_id}

  def put_org_id(org_id), do: Process.put(@tenant_key, org_id)
  def get_org_id, do: Process.get(@tenant_key)

  @impl true
  def default_options(_operation) do
    [org_id: get_org_id()]
  end

  @impl true
  def prepare_query(_operation, query, opts) do
    cond do
      opts[:skip_org_id] || opts[:schema_migration] ->
        {query, opts}

      org_id = opts[:org_id] ->
        {Ecto.Query.where(query, org_id: ^org_id), opts}

      true ->
        raise "expected org_id or skip_org_id to be set — a query reached the Repo without tenant scope"
    end
  end
end
```

**Rules:**
- `Repo.put_org_id/1` is called once per request/LiveView mount by the scope plug/hook — context code never calls it
- `prepare_query` adds the filter to the **top-level** source only — joins must join through org-scoped associations and composite FKs guarantee consistency (see migration pattern below)
- Composite FK migration pattern:

```elixir
create table(:order_items) do
  add :org_id, references(:orgs, on_delete: :delete_all), null: false
  add :order_id, references(:orders, with: [org_id: :org_id], on_delete: :delete_all), null: false
  # ...
end
create index(:order_items, [:org_id])
```

- Tables that are **not** tenant-owned (`users`, `orgs`, `push_subscriptions`, Oban's tables) are queried with `skip_org_id: true` from their owning contexts only

---

## Phoenix 1.8 Scopes

```elixir
# config/config.exs — make generators thread the scope automatically
config :tabletap, :scopes,
  default: [
    module: Tabletap.Accounts.Scope,
    assign_key: :current_scope,
    access_path: [:org, :id],
    schema_key: :org_id,
    schema_type: :binary_id,
    schema_table: :orgs
  ]
```

```elixir
# Scope struct — one shape everywhere
defmodule Tabletap.Accounts.Scope do
  defstruct [:user, :org, :venue, :membership, :role]
end
```

**Rules:**
- Context functions: `def list_items(%Scope{} = scope, opts \\ [])` — first arg, always. Inside, trust `scope.org.id`/`scope.venue.id`; the Repo raise is the backstop, not the primary filter
- Role checks live in `Scope` helpers (`Scope.can?(scope, :manage_menu)`) and LiveView `on_mount` hooks — not scattered `if role == :manager` conditionals
- Customer/public paths build an unauthenticated scope from the QR-resolved venue: `%Scope{org: org, venue: venue, role: :guest}`

---

## Phoenix LiveView

### Streams for live boards

```elixir
def mount(_params, _session, socket) do
  if connected?(socket) do
    Phoenix.PubSub.subscribe(Tabletap.PubSub, "venue:#{venue.id}:orders")
  end

  {:ok, stream(socket, :orders, Ordering.list_open_orders(scope))}
end

def handle_info({:order_updated, order}, socket) do
  # moved to a terminal state → remove; otherwise upsert in place
  if order.status in [:served, :closed, :cancelled, :refunded] do
    {:noreply, stream_delete(socket, :orders, order)}
  else
    {:noreply, stream_insert(socket, :orders, order)}
  end
end
```

**Rules:**
- Subscribe only when `connected?/1`; broadcasts happen in context functions **after** `Repo.transaction` commits
- Never `assign` a growing list — streams only
- Sort-order changes with `stream_insert(socket, :orders, order, at: index)` are allowed; full `stream(socket, :orders, list, reset: true)` only on filter changes
- JS hooks receive server data via `data-*` attributes; hooks push events with `pushEvent` — no ad-hoc channels

### Presence (waiter availability)

```elixir
# on waiter LiveView mount (on shift):
{:ok, _} = TabletapWeb.Presence.track(self(), "venue:#{venue_id}:staff", membership.id, %{role: :waiter, at: System.system_time(:second)})

# assignment reads live presence:
TabletapWeb.Presence.list("venue:#{venue_id}:staff")
```

Assignment candidates = open shift in DB **AND** present in Presence. Either alone is not enough (DB says on-shift but phone is dead; Presence flickers on reconnect — the DB shift is the intent, Presence the liveness).

---

## Oban

Queues: `default, webhooks, notifications, rollups, escalations`.

```elixir
# Escalation: schedule at assignment, cancel on accept
%{order_id: order.id, assigned_membership_id: m.id}
|> Ordering.Workers.EscalateUnacceptedOrder.new(schedule_in: 90, queue: :escalations)
|> Oban.insert()

defmodule Ordering.Workers.EscalateUnacceptedOrder do
  use Oban.Worker, queue: :escalations, max_attempts: 3

  @impl true
  def perform(%Oban.Job{args: %{"order_id" => id, "assigned_membership_id" => mid}}) do
    # Re-check state — the waiter may have accepted while this job waited.
    case Ordering.get_order_for_escalation(id) do
      %{status: :placed, waiter_membership_id: ^mid} = order -> Ordering.escalate_to_claim_board(order)
      _ -> :ok  # accepted/reassigned/cancelled — nothing to do
    end
  end
end
```

**Rules:**
- Every worker re-checks current state before acting — jobs are delayed truth, never assumed truth
- Workers are idempotent; uniqueness via `unique: [args: [:order_id], period: ...]` where duplicate scheduling is possible
- Oban jobs run without a request scope: they build their own scope from the args' org (`Repo.put_org_id(order.org_id)` first thing in `perform`)
- Nightly rollups: Oban Cron `{"0 3 * * *", Analytics.Workers.DailyRollup}` iterating venues by their local "yesterday"

---

## WaafiPay (hand-rolled client on `req`)

_Replaces the retired stripity_stripe section (launch markets have no Stripe — design-qa.md Q57; the Stripe patterns live in git history for the future card adapter). No hex SDK exists: `Tabletap.Payments.Adapters.WaafiPay` implements the `Payments.Provider` behaviour over `req`. Exact prod/sandbox hostnames MUST be confirmed with WaafiPay before Phase 3 — public sources conflict (flagged UNVERIFIED in the research note)._

### Charge (push PIN prompt on the customer's phone)

```elixir
# JSON POST with WaafiPay's shared envelope:
%{
  schemaVersion: "1.0",
  requestId: payment.id,        # our idempotency key = the payments row id
  timestamp: DateTime.to_iso8601(DateTime.utc_now()),
  channelName: "WEB",
  serviceName: "API_PURCHASE",
  serviceParams: %{
    merchantUid: creds.merchant_uid,   # the VENUE's credentials, decrypted just-in-time
    apiUserId: creds.api_user_id,
    apiKey: creds.api_key,
    paymentMethod: "MWALLET_ACCOUNT",
    payerInfo: %{accountNo: wallet_msisdn},
    transactionInfo: %{
      referenceId: order.id,
      invoiceId: order.number,
      amount: order.total |> Money.to_decimal() |> Decimal.to_string(),  # decimal string, NOT minor units
      currency: to_string(order.total.currency),
      description: "Order ##{order.number}"
    }
  }
}
# → push PIN prompt; explicit result codes for user-cancelled and timed-out
#   (~5-minute hard user timeout — well inside our 12-minute hold)
```

### Confirmation: callback + reconciliation poller, first one wins

```elixir
# callback controller: verify HMAC-SHA256 signature → insert-first on
# provider_txn_id (unique index) → enqueue Oban job → 200.
# WaafiPay does NOT retry callbacks — so the poller is the guarantee:

defmodule Tabletap.Payments.Workers.ReconcilePending do
  use Oban.Worker, queue: :webhooks, max_attempts: 5
  # every `pending` payment: transaction inquiry (HPP_GETTRANINFO) at ~30s
  # cadence + a final sweep just before hold expiry; success/failure flows
  # through the SAME idempotent confirm function as the callback path
end
```

### Refunds

`HPP_REFUNDPURCHASE` with the original transaction id + amount (full or partial). The over-refund guard (locked payment row, paid − already-refunded) lives in **our** transaction, not theirs.

**Rules:**
- Adapter code is the **only** place WaafiPay request/response shapes appear — everything else speaks `Payments.Provider` types; Mox mock (`ProviderMock`) in tests, recorded sandbox fixtures for callbacks
- Venue credentials decrypt just-in-time per call (`cloak_ecto`); never logged, never in error messages or telemetry — redact on exception
- `requestId` = our payments-row id, making charge retries idempotent on both sides
- Amounts are decimal strings from `Money.to_decimal/1` — never floats, never minor units (minor units are the future Stripe adapter's dialect)

---

## ex_money / ex_money_sql

```elixir
# v6.1 dropped the compile-time CLDR backend module (superseded by
# :localize — confirmed against current hexdocs, not memory):
# config/config.exs
config :localize, default_locale: :en, supported_locales: [:en, :ar, :so]
config :ex_money, auto_start_exchange_rate_service: false, custom_currencies: []
# auto_start_exchange_rate_service: false is deliberate — currencies never
# convert or sum across each other by design (venue.currency locks at
# first order, design-qa.md Q53), so there is nothing to fetch rates for.

# migration (generator does this — mix money.gen.postgres.money_with_currency):
execute("CREATE TYPE public.money_with_currency AS (currency_code varchar, amount numeric)")
# columns:
add :price, :money_with_currency, null: false

# schema:
field :price, Money.Ecto.Composite.Type

# usage:
Money.new(:USD, "4.50")
Money.add!(a, b)
Money.mult!(price, qty)
Money.to_string!(price, locale: venue.locale)

# provider serialization (adapter's job, never business code's):
Money.to_decimal(money) |> Decimal.to_string()            # "4.50" — WaafiPay dialect
{amount_minor, _exponent} = Money.to_integer_exp(money)   # {450, -2} — future Stripe adapter's dialect
```

**Rules:**
- Order totals are computed server-side from snapshots: `sum(unit_price × qty) + modifier deltas` — the client never sends an amount
- All items within one venue share the venue currency; cross-currency addition raising is a feature (catches bugs — USD Somali venues and ETB Jigjiga venues must never sum; org rollups report per-currency)
- Platform fee accrual = `Money.mult!(total, fee_ratio)` rounded via `Money.round/2` before writing the `platform_fee_ledger` row

---

## qr_code

```elixir
# table QR — SVG for the print sheet
url = url(~p"/t/#{table.qr_token}")

svg =
  url
  |> QRCode.create(:high)                # :high error correction — laminated, stained tables
  |> QRCode.render(:svg, %QRCode.Render.SvgSettings{qrcode_color: "#000", scale: 6})
```

**Rules:**
- Error correction `:high` for physical table codes (they get dirty); `:medium` fine for on-screen codes
- QR encodes only the opaque token URL — never table/venue ids directly; rotating `qr_token` invalidates stolen codes
- Serve-confirmation compares the scanned token to `order.table.qr_token` server-side — the client sends the raw decoded string only

---

## web_push_ex (VAPID Web Push)

```elixir
# subscription captured by a JS hook (PushManager.subscribe) → POST → push_subscriptions row
message = Jason.encode!(%{title: "New order #48", body: "Table 7 · 3 items", tag: "order-#{id}", url: ~p"/waiter"})

for sub <- Notifications.subscriptions_for_user(user_id) do
  case WebPushEx.request(message, to_web_push_subscription(sub)) do
    {:error, :gone} -> Notifications.delete_subscription(sub)   # expired — prune
    _ -> :ok
  end
end
```

**Rules:**
- Push is fan-out only — the in-app PubSub message is always sent too; push failing must never lose information
- Prune `410 Gone` subscriptions on send
- Payloads carry a `url` the service worker opens on click, and a `tag` so repeated order updates collapse

---

## Swoosh

- Adapter: local dev mailbox in dev; real provider (Resend/SES) in prod via `runtime.exs`
- All emails from `Tabletap.Mailer` with venue branding on customer-facing mails (receipt) and platform branding on auth/staff-invite mails
- Emails are enqueued through Oban (`notifications` queue), never sent inline in a request

---

## ex_aws_s3 (photos)

```elixir
# direct-to-bucket presigned upload from the menu builder (LiveView allow_upload external)
{:ok, presigned} = ExAws.Config.new(:s3) |> ExAws.S3.presigned_url(:put, bucket, key, expires_in: 900)
```

- Images resized client-side before upload (max 1600px) — LiveView `allow_upload` with `external: &presign/2`
- Public read via CDN URL stored on the record; never proxy image bytes through the app
