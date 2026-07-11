# Ethiopia (Jigjiga) payments: eBirr, Chapa, Telebirr (research notes, 2026-07-07)

Companion to `somalia-payments-waafipay-zaad.md`. Scope: the founder's third MVP city — Jigjiga,
Somali Region, Ethiopia — where he names **eBirr**.

## TL;DR

**eBirr is the right wallet for Jigjiga, but it has no public developer API — the integrable path is
[Chapa](https://chapa.co/), an NBE-licensed Ethiopian payment gateway whose Direct Charge API covers
Coopay-Ebirr, telebirr, M-Pesa, CBEBirr and more.** eBirr is genuinely dominant in Jigjiga (500k+
customers within a year of launch, ~60% of them in Jigjiga —
[The Reporter](https://www.thereporterethiopia.com/11255/)), but it publishes no docs/portal
([ebirr.com](https://ebirr.com/)). Chapa's flow is WaafiPay-shaped: initiate a charge → **USSD push
PIN prompt** on the customer's phone → verify/webhook
([developer.chapa.co](https://developer.chapa.co/payment-methods)). Chapa even has **split payments
via subaccounts** — something WaafiPay lacks — though settlement is ETB-only.

**Ethiopia is necessarily a second `PaymentProvider` implementation** (`Providers.Chapa`): WaafiPay
covers no Ethiopian wallet. And Ethiopia brings three things Somalia doesn't: **ETB as the mandatory
venue currency** (multi-currency is now real at launch), a **data-localization law** (personal data
collected in Ethiopia must be stored on servers *in* Ethiopia — Proclamation 1321/2024), and an
NBE licensing perimeter that needs a legal opinion. **Recommendation: launch Hargeisa + Mogadishu
first on WaafiPay; Jigjiga as a fast-follow phase 2** once Chapa sandbox + the legal questions clear.

---

## 1. eBirr — who it is, and the API reality

- **Operator**: consumer app published by "EBIRR MOBILE FINANCIAL SERVICES PLC"; merchant app by
  "Ebirr Trading Plc" ([Google Play](https://play.google.com/store/apps/details?id=com.safarifone.ebirr),
  [Ebirr Merchant](https://play.google.com/store/apps/details?id=com.safarifone.merchant.ebirr)). HQ:
  Getu Commercial Business Center, Addis Ababa; call center 9119; info@ebirr.com ([ebirr.com](https://ebirr.com/)).
- **The Somali/WAAFI connection is real but only at the software layer**: both the WAAFI and eBirr
  apps ship under the `com.safarifone.*` namespace; Safarifone states it powers "ZAAD, EVCPLUS,
  SAHAL, EBIRR, JEEB, KAASHPLUS" ([safarifone.com](https://www.safarifone.com/en)). Same MFS vendor,
  different operators and rails.
- **License**: ebirr.com claims "authorised and regulated by the NBE", **but eBirr appears nowhere on
  NBE's licensed Payment Instrument Issuer list**
  ([nbe.gov.et](https://nbe.gov.et/payment-instrument-issuers-system-operators/)). It operates
  bank-led, in partnership with Cooperative Bank of Oromia ("Coopay-Ebirr", USSD `*841#`, app, web —
  [coopbankoromia.com.et](https://coopbankoromia.com.et/coopay-ebirr/)), plus Kaafi Microfinance, Nib,
  Wegagen, Ahadu ([ebirr.com](https://ebirr.com/)). **UNVERIFIED which entity holds which license** —
  assume the partner bank/MFI is the regulated party.
- **Jigjiga dominance**: >500k customers within a year of Somali-Region launch, **60% in Jigjiga**,
  800 agents, in partnership with Coopbank ([The Reporter](https://www.thereporterethiopia.com/11255/)).
  This is our target wallet.
- **Developer API: none public.** No portal, no docs, nothing on GitHub. Integration = direct bizdev
  (info@ebirr.com) — terms UNVERIFIED — **or via Chapa**, which lists "Coopay-Ebirr" as a Direct
  Charge method with *unlimited* pay-in ([developer.chapa.co/payment-methods](https://developer.chapa.co/payment-methods)).
- **Flow**: USSD (`*841#`) + app + PIN; merchant payments and QR supported per Coopbank
  ("E-commerce & QR Code Payments"). Via Chapa Direct Charge the customer gets a **USSD push
  notification to authorize with PIN** — same UX class as ZAAD/EVC Plus.
- **Merchant onboarding**: register at Coopbank branches/agents or self-registration via USSD/web
  ([coopbankoromia.com.et](https://coopbankoromia.com.et/coopay-ebirr/)); café-specific merchant
  requirements UNVERIFIED — expect Ethiopian business license + TIN.
- **Currency**: ETB. No multi-currency wallet evidence (unlike ZAAD's USD/SLSh).

## 2. The integrable gateway + alternatives in Jigjiga

- **Chapa — the recommended rail** ([chapa.co](https://chapa.co/), docs [developer.chapa.co](https://developer.chapa.co/)):
  NBE-licensed **payment gateway operator** (on the official list —
  [nbe.gov.et](https://nbe.gov.et/payment-instrument-issuers-system-operators/)). Hosted checkout +
  **Direct Charge**: `POST https://api.chapa.co/v1/charges?type={method}` → USSD push to the
  customer → `Authorize Transaction` step (some methods add OTP; sensitive fields must be encrypted) →
  verify endpoint + webhooks ([charge docs](https://developer.chapa.co/charge/initiate-payments),
  [authorize](https://developer.chapa.co/charge/authorize-payments)). Methods: telebirr, M-Pesa,
  CBEBirr, **Coopay-Ebirr**, AwashBirr, Amole, cards, PayPal; per-method ETB limits (telebirr
  1–75,000 ETB; Coopay-Ebirr unlimited) ([payment methods](https://developer.chapa.co/payment-methods)).
  **Split payments exist**: subaccounts (bank account per vendor), flat or percentage splits,
  **settlement ETB-only** ([split docs](https://developer.chapa.co/integrations/split-payment)).
  Self-serve dashboard signup; live keys require business KYC — Ethiopian business license/TIN
  ([getting started](https://developer.chapa.co/getting-started)). Test mode + community SDKs
  ([chapa-nodejs](https://github.com/fireayehu/chapa-nodejs), [chapa-python](https://github.com/Chapa-Et/chapa-python)).
  Fees: not confirmed from primary sources (UNVERIFIED — commonly cited ~3.5% for cards, less for wallets; ask).
- **Telebirr** (Ethio Telecom, license NPS PII/01/2021): real public developer portal —
  [developer.ethiotelecom.et/docs](https://developer.ethiotelecom.et/docs/) — Huawei "Fabric" payment
  gateway, H5 web checkout (C2B), mandates; onboarding requires presenting a business license
  ([telebirr-php](https://github.com/MelakuDemeke/telebirr-php),
  [Node integration](https://github.com/Solomonkassa/Nodejs-Telebirr-Integration)). Largest wallet
  nationally; early API quality complaints from local devs
  ([Addis Zeybe](https://addiszeybe.com/developers-indicate-flaws-in-telebirr-api-suggest-an-early-adjustment)).
  Jigjiga share vs eBirr: UNVERIFIED, but eBirr is the regionally-reported leader.
- **M-Pesa Ethiopia** (Safaricom, license NPS/PII/003/2023): real open API portal —
  [developer.safaricom.et](https://developer.safaricom.et/) — tokens, C2B validation/confirmation
  URLs, reversals ([TechAfrica](https://techafricanews.com/2025/03/12/m-pesa-opens-doors-for-mekelle-developers-with-new-api-portal/)).
  Somali-Region penetration UNVERIFIED — likely thin vs eBirr.
- **HelloCash (BelCash)**: the *former* Somali-Region leader via Somali Microfinance (now **Shabelle
  Bank** — [2merkato](https://www.2merkato.com/news/alerts/7072-ethiopia-somali-micro-finance-becomes-shabelle-bank))
  and Lion Bank ([Finextra 2015](https://www.finextra.com/pressarticle/58590/hellocash-financial-services-platform-goes-live-in-ethiopia)).
  No public API docs found; not on the NBE issuer list (bank-led). Regional momentum has visibly
  shifted to eBirr ([The Reporter](https://www.thereporterethiopia.com/11255/)). Skip.

## 3. Does WAAFI/Salaam reach Ethiopia? **No.**

- WaafiPay's docs and site list WAAFI, ZAAD, EVC Plus, Sahal, cards, banks — **no Ethiopian wallet,
  no ETB** ([docs.waafipay.com](https://docs.waafipay.com/), [waafipay.com](https://waafipay.com/)).
  Salaam Bank's Waafi card push covers Somalia/Djibouti/Horn, not Ethiopia's licensed wallet market
  ([Paymentology/Salaam](https://thepaymentsassociation.org/article/waafi-by-salaam-bank-taps-paymentology-to-enable-somalias-contactless-payment-vision/)).
- The only bridge is Safarifone as shared software vendor (§1) — commercially irrelevant to us.
- **Conclusion: Ethiopia = a second, separate `PaymentProvider` implementation.** No gateway reuse.

## 4. Regulatory reality for a foreign SaaS

- **Licensing perimeter**: only NBE-licensed entities may issue payment instruments or operate
  payment systems (National Payment System Amendment **Proclamation 1282/2023** —
  [NBE PDF](https://nbe.gov.et/wp-content/uploads/2023/04/National-Payment-SystemAmendement-Proclamation-No.1282-2023.pdf),
  [Ethiolex summary](https://ethiolex.com/key-amendments-introduced-by-national-payment-system-amendment-proclamation-no-1282-2023/)).
  Foreign investment in PII/PSO is now permitted (capital in forex + "investment protection fee").
  Our model — **the café is the merchant on a licensed gateway (Chapa); TableTap only initiates
  charges on the merchant's credentials** — mirrors the Somalia posture and should sit outside the
  perimeter, but **UNVERIFIED**: whether NBE treats an ordering platform routing payment initiation
  as an unlicensed operator, and whether Chapa's merchant agreement permits third-party initiation
  ([merchant agreement](https://chapa.co/more/merchant-service-agreement)). Get an Ethiopian legal
  opinion + Chapa's written OK before build.
- **The split-payment temptation**: using Chapa subaccounts (platform fee as a percentage split)
  requires **TableTap itself to be the Chapa merchant** → Ethiopian entity, business license, TIN,
  KYC — and pulls us toward the licensing perimeter. Avoid at launch; per-venue credentials first.
- **Data localization — the biggest landmine**: Personal Data Protection **Proclamation 1321/2024**
  requires personal data collected in Ethiopia to be **stored on a server/data center located in
  Ethiopia**, with prior-approval regimes for cross-border transfer of sensitive data
  ([text](https://www.metaappz.com/References/ethiopian_laws/federal/pr_1321_2024/en/txt),
  [Digital Policy Alert](https://digitalpolicyalert.org/event/24922-implemented-personal-data-protection-proclamation-proclamation-no-13212024-including-data-localisation-requirements)).
  A foreign-hosted Phoenix app taking Jigjiga customers' names/phone numbers is squarely in scope.
  Enforcement maturity and any grace periods: UNVERIFIED — legal opinion required; options range from
  an Ethiopia-located replica/region to minimizing stored PII for ET venues.
- **ETB and getting our fee out**: FX Directive **FXD/01/2024** liberalized the regime — market-set
  rates, and banks can process profit/dividend repatriation for **registered foreign investments**
  without prior NBE approval ([NBE PDF](https://nbe.gov.et/wp-content/uploads/2024/07/FXD012024-FOREIGN-EXCHANGE-1-1.pdf),
  [trade.gov](https://www.trade.gov/market-intelligence/ethiopia-finance-launches-new-forex-directive)).
  But TableTap with *no* registered Ethiopian investment, earning ETB fees from cafés, has **no clean
  repatriation lane** — ETB is not freely convertible offshore. Realistic options: (a) invoice
  Jigjiga venues in USD from abroad (their forex access is the hard part), (b) accrue ETB locally via
  a partner/agent, (c) eventually register a local entity. UNVERIFIED which is practical — treat the
  Jigjiga platform fee as an open commercial question, not a blocker for the pilot.

## 5. Currency implication — ETB is unavoidable

- All Ethiopian mobile-money methods are **ETB-denominated**; Chapa's per-method limits are quoted in
  ETB and subaccount settlement is ETB-only ([payment methods](https://developer.chapa.co/payment-methods),
  [split docs](https://developer.chapa.co/integrations/split-payment)). Chapa lists USD only for
  cards/PayPal-style international collection, not wallets.
- **Consequence**: TableTap's "venue currency locks at first order" design must genuinely support
  **USD venues (Hargeisa, Mogadishu) and ETB venues (Jigjiga) from launch** — Money type, per-venue
  currency on menus/receipts/refunds, and a fee ledger that accrues in the venue's currency. No FX
  conversion inside the app; the repatriation problem (§4) lives in the business layer.

---

## Architecture implications for TableTap

- **Second provider, not a variant**: `Providers.Chapa` alongside `Providers.Waafipay` under the same
  `Payments.Provider` behaviour. Differences to absorb in the behaviour: Chapa is **two-step**
  (initiate charge → optional authorize/OTP step → verify), vs WaafiPay's single blocking call; both
  end in a customer PIN prompt, and both need a `lookup/2` (Chapa `verify`) reconciliation poll.
  Chapa webhook retry semantics: UNVERIFIED — keep the mandatory-poll design regardless.
- **Credentials model unchanged**: `venues.payment_provider` gains `chapa`; encrypted per-venue
  `chapa_secret_key` (venue signs up on Chapa's self-serve dashboard with its own Ethiopian business
  license — notably *easier* than WAAFI's in-person onboarding). Money lands in the café's account;
  platform fee stays a ledger entry (in ETB for ET venues).
- **Do not use Chapa split payments at launch** (forces us to be merchant-of-record + Ethiopian
  entity); revisit once a local entity exists — it would then give us the per-transaction fee split
  Stripe Connect used to.
- **Phasing recommendation**: **Hargeisa + Mogadishu first (WaafiPay, USD); Jigjiga phase 2.**
  Gate Jigjiga on: (1) Chapa test-mode spike proving Coopay-Ebirr Direct Charge end-to-end incl.
  timeout/decline codes; (2) Ethiopian legal opinion on PDPP 1321/2024 localization + the payment
  licensing perimeter; (3) a decided fee-collection story for ETB. None of these look fatal — the
  rails and the demand (eBirr's Jigjiga dominance) are real — but shipping all three cities on day
  one triples regulatory surface for one team.

**Open questions for Chapa/eBirr contact**: Chapa wallet fee schedule + settlement cadence; webhook
retry policy; third-party initiation permitted under merchant agreement; Coopay-Ebirr USSD-push
timeout window (WaafiPay's is 5 min — need Chapa's equivalent); refund API coverage for Coopay-Ebirr;
whether eBirr offers a direct merchant API privately and at what terms.
