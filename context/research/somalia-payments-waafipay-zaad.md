# Somalia payments: WaafiPay, ZAAD, eDahab (research notes, 2026-07-07)

## TL;DR

**Yes — TableTap can build on WaafiPay.** It is a real, documented, REST/JSON payment gateway
([docs.waafipay.com](https://docs.waafipay.com/)) run by the Salaam/Hormuud/Telesom group (HQ: Salaam Tower,
Djibouti), aggregating exactly the wallets our market uses: **WAAFI, ZAAD (Telesom), EVC Plus (Hormuud), Sahal
(Golis)** plus cards, bank accounts, and M-Pesa ([waafipay.com](https://waafipay.com/)). It has a sandbox with
test wallet numbers, purchase + preauthorize/commit/cancel + refund + transaction-inquiry APIs, HMAC-signed
webhooks, and USD/SLSH/DJF currencies. **eDahab** (Somtel/Dahabshiil) is a viable second rail with its own API
([docs.edahab.net](https://docs.edahab.net/)).

What changes vs Stripe: **everything marketplace-shaped dies.** No Connect, no `application_fee_amount`, no
PaymentSheet/Apple Pay, no 3DS, no chargebacks, no Stripe Billing. Payment becomes a **push-to-phone PIN prompt**
(customer enters wallet PIN within a 5-minute window) instead of a card form. Each venue gets its **own WaafiPay
merchant credentials** that our platform charges against; the platform fee becomes a **ledger + monthly invoice**,
not a per-transaction split. Biggest open risk: **webhook deliveries are not retried** — we must poll
`HPP_GETTRANINFO` for reconciliation — and **marketplace/split-payment features don't exist**.

---

## 1. WaafiPay — the gateway

**Docs**: [docs.waafipay.com](https://docs.waafipay.com/) — sections: Quickstart, Purchase, PreAuthorization,
Hosted Payment Page (HPP), Webhooks, plus WooCommerce/Odoo plugins and SDK samples on
[github.com/waafipay](https://github.com/waafipay). Merchant portal: [merchant.waafipay.com](https://merchant.waafipay.com/).

**Protocol**: single endpoint `POST /asm`, JSON in/out, action selected by `serviceName`.
Base URLs per the docs' API introduction ([docs.waafipay.com/api-introduction](https://docs.waafipay.com/api-introduction)):
sandbox `https://sandbox.waafipay.com/asm`, production `https://api.waafipay.net/asm`.
(Third-party guides show `sandbox.waafipay.net` / `api.waafipay.com` — the .com/.net split is inconsistent across
sources; **confirm exact hosts with WaafiPay at onboarding**.)

**Auth**: `merchantUid` + `apiUserId` + `apiKey` in every direct-API request; HPP additionally uses `storeId` +
`hppKey` ([HPP docs](https://docs.waafipay.com/hpp-api)). Issued at merchant registration — done at "WAAFI HQ
Offices (Telesom, Zaad, Golis, WAAFI SAB)" per the docs intro; no self-serve signup documented. Contact:
payments@waafi.com ([support](https://docs.waafipay.com/support)).

**APIs** (all via `serviceName` on `/asm`):
- `API_PURCHASE` — direct debit of a wallet: `paymentMethod: "MWALLET_ACCOUNT"`, `payerInfo.accountNo`
  (customer's mobile in international format, e.g. `252611111111`), `transactionInfo` {referenceId, invoiceId,
  amount, currency, description}. Success: `responseCode: "2001"`, `params.state: "APPROVED"`, `transactionId`,
  `merchantCharges` ([Purchase API](https://docs.waafipay.com/purchase-api)).
- `API_PREAUTHORIZE` / `API_PREAUTHORIZE_COMMIT` / `API_PREAUTHORIZE_CANCEL` — hold funds, then capture or
  release by `transactionId` ([PreAuthorization API](https://docs.waafipay.com/preauthorization-api)). Hold
  duration is **not documented** — ask at onboarding.
- `API_REVERSAL` — reverses a purchase **within 24h, before settlement** ([Purchase API](https://docs.waafipay.com/purchase-api)).
- `HPP_PURCHASE` — hosted payment page (redirect, success/failure callback URLs); `HPP_REFUNDPURCHASE` —
  **full or partial refunds** by referenceId/transactionId; `HPP_GETTRANINFO` — transaction status inquiry
  ([HPP docs](https://docs.waafipay.com/hpp-api)).
- **Payouts/disbursements: not in the public docs.** No credit/transfer serviceName is documented. UNVERIFIED
  whether a B2C payout API exists privately — ask.

**Webhooks** ([docs.waafipay.com/webhooks](https://docs.waafipay.com/webhooks)): registered via API
(`WEBHOOK_LIST/UPDATE/DELETE` to manage); events `authorization` and `refund` (+ unsigned `webhook.test`).
Signed with HMAC-SHA256 over `{timestamp}.{event_id}.{raw_body_bytes}`, headers `X-Webhook-Timestamp`,
`X-Webhook-Event-Id`, `X-Webhook-Signature`; reject if timestamp >5 min old. Payment status values:
`APPROVED, FAILED, DECLINED, CANCELED, EXPIRED, TIMEOUT`. **"Failed deliveries are not automatically
retried"** — a hard operational constraint; polling reconciliation is mandatory.

**Sandbox**: yes, with test wallet numbers for EVCPlus/ZAAD/SAHAL/WAAFI and test Visa/Mastercard numbers
([Quickstart](https://docs.waafipay.com/quickstart)).

**Wallets/currencies**: MWALLET_ACCOUNT covers WAAFI, ZAAD, EVCPlus, Sahal; site also lists M-Pesa and cards
([waafipay.com](https://waafipay.com/)). Currencies documented: **USD, SLSH, DJF** (ISO 4217) — note SLSH =
Somaliland shilling; SOS is not shown in examples. USD is the working default.

**Fees**: not published. The docs' example response shows `merchantCharges: "0.1"` on a $10 purchase (1%) —
indicative only, UNVERIFIED as a rate card. Telesom's own ZAAD e-payment page publishes **1% per transaction +
$100 installation** ([telesom.com/business/epayment](https://www.telesom.com/business/epayment)) — a reasonable anchor.

**Onboarding**: in-person/manual (documents + registration at WAAFI offices; Telesom's ZAAD variant requires a
Somaliland physical address, business license, $100 fee). Timeline not published — assume days-to-weeks, not
Stripe's minutes. **This makes venue onboarding an offline step in our funnel.**

## 2. ZAAD directly (Telesom)

- ZAAD is Telesom's mobile money (Somaliland, launched June 2009, licensed by the central bank of Somaliland;
  USSD-based, works on any phone) ([telesom.com/personal/zaad](https://www.telesom.com/personal/zaad),
  [GSMA case study](https://www.gsma.com/solutions-and-impact/connectivity-for-good/mobile-for-development/region/sub-saharan-africa-region/reaching-half-of-the-market-women-and-mobile-money-the-example-of-telesom-in-somaliland/)).
- Telesom **does** expose a direct "e-Payment … part of the ZAAD API" for websites/apps: eligibility = physical
  address in Somaliland + business license + $100 application fee; pricing 1%/transaction
  ([telesom.com/business/epayment](https://www.telesom.com/business/epayment)). In practice WaafiPay is the
  group's unified gateway over the same rails and adds EVC+/Sahal/cards — prefer WaafiPay unless the pilot is
  ZAAD-only and Telesom's direct terms are better.
- Customers pay merchants today via USSD short codes (merchant payments are free to the payer — GSMA); ZAAD
  handles both USD and SLSh with in-wallet conversion ([GSMA](https://www.gsma.com/solutions-and-impact/connectivity-for-good/mobile-for-development/region/sub-saharan-africa-region/reaching-half-of-the-market-women-and-mobile-money-the-example-of-telesom-in-somaliland/)).
  USD is the dominant denomination. Exact merchant-pay USSD string: not confirmed from primary sources (UNVERIFIED).

## 3. eDahab (Somtel / Dahabshiil) — second rail

- API docs: [docs.edahab.net](https://docs.edahab.net/); sandbox signup at
  [edahab.net/sandbox](https://edahab.net/sandbox/). REST/JSON.
- Auth: `apiKey` in body + request **hash = hex(SHA256(json_body + secret))** passed as query param —
  e.g. `https://edahab.net/api/api/IssueInvoice?hash={{hash}}`
  ([integration guide](https://abdorizak.dev/blog/e-dahab-integration)).
- Three operations: **IssueInvoice** (fields: apiKey, edahabNumber, amount, agentCode, returnUrl, currency
  USD|SLSH), **CheckInvoiceStatus** (pending/success), **credit account** (agent disbursement)
  ([docs.edahab.net](https://docs.edahab.net/), guide above). Payment completes via phone **pop-up** (PIN) or
  the eDahab web portal; numbers starting with 62 don't support pop-up (guide). Webhooks/notifications are
  advertised on the docs intro; **refunds are not documented publicly** (UNVERIFIED — assume manual).
- Coverage: Somtel subscribers (Dahabshiil group), strong in Somaliland — a genuine competitor rail to
  ZAAD in Hargeisa. Worth adding as a second `PaymentProvider` after the pilot, not for MVP.

## 4. Transaction UX: push payment, timeouts, failures

- Flow: our backend calls `API_PURCHASE` (or `API_PREAUTHORIZE`) with the customer's wallet number → the
  customer gets a prompt on their phone (WAAFI app popup / USSD PIN request) → enters PIN → gateway returns
  `state: APPROVED` ([integration guide](https://abdorizak.dev/blog/waafi-integration)). Community SDKs treat
  the call as one synchronous round-trip that resolves after PIN entry (UNVERIFIED in official docs — design
  for both: handle a long-blocking HTTP call *and* rely on `HPP_GETTRANINFO`/webhook as source of truth).
- **Timeout: 5 minutes.** `5309 RCS_HPP_USERACTION_TIMEOUT` = "User didn't process the transaction in 5
  minutes"; `5306 RCS_HPP_USERACTION_CANCELLED` = user rejected
  ([api-introduction](https://docs.waafipay.com/api-introduction)). Other observed failures: insufficient
  balance / declines (e.g. `responseCode 5206`, `errorCode E10205`).
- **Our 12-minute stock hold fits comfortably**: the payment attempt self-resolves in ≤5 minutes, faster and
  more deterministic than card + 3DS. We could even shorten the hold to ~6–7 min later.
- **Refunds are programmatic**: `HPP_REFUNDPURCHASE` (full/partial, anytime) and `API_REVERSAL` (≤24h,
  pre-settlement). eDahab refunds: undocumented → treat as manual.
- **Chargebacks do not exist** in Somali mobile money — PIN entry is final authorization. No dispute-evidence
  flow, no chargeback fees, no `radar`-style review. Fraud shifts to account-takeover/social engineering, which
  is the wallet operator's problem, not ours.

## 5. Marketplace / multi-tenant reality

- **No split payments, no application fees, no Connect-equivalent.** Nothing in WaafiPay's docs or marketing
  mentions marketplace/sub-merchant/split features ([docs](https://docs.waafipay.com/), [site](https://waafipay.com/)).
  Same for eDahab.
- The workable model (and what the credential design implies): **each venue registers its own WaafiPay merchant
  account** and hands us its `merchantUid`/`apiUserId`/`apiKey` (+ `storeId`/`hppKey` if HPP); our platform
  charges customers against the venue's credentials, so money lands directly in the venue's settlement account —
  same money flow as Stripe direct charges, preserving our no-money-transmission posture.
- The alternative — platform collects centrally and settles to venues — requires disbursement rails we haven't
  verified and makes us a money transmitter under CBS/Bank of Somaliland rules. **Avoid.**
- Platform fee: cannot be taken per-transaction at the gateway. Record it in a ledger per order and collect it
  with the subscription invoice (see Architecture implications).
- What Somali multi-merchant platforms do: no primary-source documentation found (UNVERIFIED); anecdotally
  local e-commerce integrates per-merchant WaafiPay/eDahab credentials, consistent with the model above.

## 6. Currency + regulatory

- **USD is the primary mobile-money denomination.** Somalia is heavily dollarized; ~two-thirds or more of
  payments go through mobile money, and >95% of physical shillings are estimated counterfeit
  ([African Business](https://african.business/2021/09/trade-investment/somalia-points-the-way-to-first-cashless-society),
  [Wikipedia: Mobile money in Somalia](https://en.wikipedia.org/wiki/Mobile_money_in_Somalia)). ZAAD supports
  USD + SLSh; EVC Plus is USD; WaafiPay accepts USD/SLSH/DJF.
- **Licensing**: Central Bank of Somalia issued its **first mobile money license to Hormuud (EVC Plus) in
  Feb 2021** ([Connecting Africa](https://www.connectingafrica.com/mobile-money/central-bank-of-somalia-issues-first-mobile-money-license)).
  ZAAD is licensed by the **central bank of Somaliland** — a separate jurisdiction; a Hargeisa pilot sits under
  Somaliland rules, not CBS ([telesom.com/personal/zaad](https://www.telesom.com/personal/zaad)).
- **E-invoicing / fiscal receipts**: no e-invoicing or fiscal-device mandate found for Somalia or Somaliland —
  silence confirmed as far as searchable primary sources go (UNVERIFIED absence). Our own receipts suffice.

---

## Architecture implications for TableTap

**What dies** (from `context/architecture.md` §Payments):
- Stripe Connect Express onboarding, `stripe_account_id`, `stripe_charges_enabled`, `application_fee_amount`.
- `stripity_stripe`, Payment Element, `@stripe/stripe-react-native` PaymentSheet, Apple/Google Pay.
- 3DS and "late 3DS success" resurrection logic (Q21) — replaced by the simpler 5-min push-prompt window.
- Card minimums (~$0.50, Q34) — no documented WaafiPay minimum (verify at onboarding).
- Chargeback evidence/dispute handling — no chargebacks exist.
- Stripe Billing subscriptions + `stripe_customer_id`.

**What replaces it**:
- `venues` gains `payment_provider` (`waafipay` | `cash_only`), and encrypted (Cloak) per-venue credentials:
  `waafipay_merchant_uid`, `waafipay_api_user_id`, `waafipay_api_key` (+ optional `hpp_*`). Onboarding = venue
  registers with WAAFI offices (offline, days), then pastes credentials into the owner dashboard; a $0.01-style
  verification charge or `HPP_GETTRANINFO` ping validates them (replaces `account.updated` webhook gating).
- Checkout: customer enters/confirms their **wallet phone number** (prefill from `customer_users`), taps Pay →
  order goes `pending_payment` + stock reserved (unchanged, Q1) → backend `API_PURCHASE` against the venue's
  credentials → customer approves PIN prompt on phone → APPROVED = `placed`; `5306/5309/decline` releases the
  hold immediately (no 12-min wait needed on explicit failure). Keep the 12-min sweeper as backstop.
- Source of truth: gateway response + `authorization` webhook (HMAC-verified, Oban-processed, idempotent by
  `X-Webhook-Event-Id`) **plus a mandatory `HPP_GETTRANINFO` poll** for any order stuck in `pending_payment`
  >6 min, because webhooks are not retried.
- Refunds: `payments.provider` gains `waafipay`; `refunds` keeps working via `HPP_REFUNDPURCHASE`
  (partial supported); keep the loud-failure alert (Q23) since refund webhooks also don't retry.
- **Platform fee**: per-order `application_fee` column becomes a **ledger entry** (`platform_fees` or reuse
  `payments.application_fee` as "accrued fee"); collected monthly.
- **SaaS billing without Stripe Billing**: platform holds its *own* WaafiPay merchant account; an Oban monthly
  job issues an invoice (subscription + accrued per-order fees) and fires `API_PURCHASE` against the **owner's
  wallet number** — the owner approves a PIN prompt. No recurring-mandate API is documented, so billing is
  "push-prompt each cycle" with dunning states (`past_due` after N failed prompts → existing billing wall).
  Cash/manual settlement stays a fallback.
- Mobile apps: no Stripe RN SDK needed — payment UI is just "enter wallet number, watch order status", which
  Phoenix Channels already covers. (Cheaper Phase 8.)

**PaymentProvider abstraction (Elixir)**:

```elixir
defmodule Tabletap.Payments.Provider do
  @type credentials :: map()          # per-venue, decrypted at call time
  @type charge_request :: %{order_id: id, amount: Money.t(), payer_ref: String.t(), reference_id: String.t()}
  @type charge_result ::
          {:ok, %{provider_tx_id: String.t(), state: :approved}}
          | {:error, :timeout | :rejected | :insufficient_funds | :invalid_credentials | {:provider, code :: String.t()}}

  @callback charge(credentials, charge_request) :: charge_result          # WaafiPay: API_PURCHASE (blocking ≤5min → run in Oban/Task)
  @callback refund(credentials, provider_tx_id :: String.t(), Money.t()) :: {:ok, map()} | {:error, term()}
  @callback lookup(credentials, reference_id :: String.t()) :: {:ok, status :: atom()} | {:error, term()}  # HPP_GETTRANINFO — reconciliation
  @callback verify_webhook(conn_raw_body :: binary(), headers :: map(), secret :: binary()) :: :ok | :error
end
# Implementations: Providers.Waafipay (now), Providers.Edahab (later), Providers.Cash (existing POS path)
```

Charge calls can block up to 5 minutes — run them in a supervised Task/Oban job, never in the LiveView process;
the order tracker updates via PubSub when the job (or webhook) resolves.

**Open questions for WaafiPay onboarding call**: exact prod/sandbox hosts; preauthorize hold duration; payout
API existence; fee schedule; settlement cadence to venue accounts; merchant-account timeline for a small café;
any per-transaction minimum; SLSH support in Hargeisa vs USD-only.
