defmodule Tabletap.Payments.Provider do
  @moduledoc """
  Provider-agnostic wallet-payment contract (build-plan.md Feature 09;
  supersedes the retired Stripe Connect design — design-qa.md Q57).
  `Tabletap.Payments` speaks only these types; WaafiPay's request/response
  shapes are the adapter's problem alone (library-docs.md "Adapter code
  is the only place WaafiPay request/response shapes appear").

  Every callback takes `credentials` first — the **venue's own** merchant
  credentials, decrypted just-in-time by the caller (never logged, never
  serialized into an error). A charge/refund/lookup call always happens
  against one specific venue's money, never the platform's.

  Tests mock this behaviour via Mox (`Tabletap.Payments.ProviderMock`) —
  no test ever hits a real provider API (code-standards.md).
  """

  @type credentials :: %{
          merchant_uid: String.t(),
          api_user_id: String.t(),
          api_key: String.t()
        }

  @type charge_request :: %{
          request_id: String.t(),
          reference_id: String.t(),
          invoice_id: String.t(),
          amount: Money.t(),
          wallet_msisdn: String.t(),
          description: String.t()
        }

  @type charge_result ::
          {:ok, %{provider_txn_id: String.t(), state: :approved}}
          | {:error,
             :timeout
             | :rejected
             | :insufficient_funds
             | :invalid_credentials
             | {:provider, code :: String.t()}}

  @type lookup_result ::
          {:ok, %{provider_txn_id: String.t() | nil, state: :approved | :pending | :failed}}
          | {:error, term()}

  @type refund_result :: {:ok, %{provider_refund_id: String.t()}} | {:error, term()}

  @doc "Push a PIN prompt to `wallet_msisdn` for `amount`, against `credentials`. May take up to ~5 minutes to resolve — never call from a LiveView process."
  @callback charge(credentials, charge_request) :: charge_result

  @doc "Refunds `amount` (full or partial) against a previously-approved `provider_txn_id`."
  @callback refund(credentials, provider_txn_id :: String.t(), amount :: Money.t()) ::
              refund_result

  @doc "Transaction-inquiry: the guaranteed reconciliation path (callbacks are not retried — library-docs.md)."
  @callback lookup(credentials, reference_id :: String.t()) :: lookup_result

  @doc "Verifies an inbound callback's HMAC signature and, on success, returns its decoded payload."
  @callback verify_callback(raw_body :: binary(), headers :: map()) ::
              {:ok, map()} | :error
end
