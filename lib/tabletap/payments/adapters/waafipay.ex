defmodule Tabletap.Payments.Adapters.WaafiPay do
  @moduledoc """
  Hand-rolled `req`-based client for WaafiPay's `/asm` gateway
  (library-docs.md "WaafiPay (hand-rolled client on `req`)") — no hex SDK
  exists. Single endpoint, JSON in/out, action selected by `serviceName`.

  This module is the **only** place WaafiPay's request/response shapes
  appear (library-docs.md rule) — every caller elsewhere speaks
  `Payments.Provider`'s types.

  Hostnames are UNVERIFIED beyond the docs' stated sandbox URL
  (research/somalia-payments-waafipay-zaad.md flags a .com/.net
  inconsistency across sources) — `config :tabletap, :waafipay, api_url`
  is what actually gets called; confirm the real production host with
  WaafiPay directly before relying on the `runtime.exs` default.
  """
  @behaviour Tabletap.Payments.Provider

  alias Tabletap.Payments.Provider

  @schema_version "1.0"
  @channel_name "WEB"

  @impl Provider
  def charge(credentials, request) do
    body =
      envelope("API_PURCHASE", request.request_id, %{
        merchantUid: credentials.merchant_uid,
        apiUserId: credentials.api_user_id,
        apiKey: credentials.api_key,
        paymentMethod: "MWALLET_ACCOUNT",
        payerInfo: %{accountNo: request.wallet_msisdn},
        transactionInfo: %{
          referenceId: request.reference_id,
          invoiceId: request.invoice_id,
          amount: decimal_amount(request.amount),
          currency: to_string(request.amount.currency),
          description: request.description
        }
      })

    case post(body) do
      {:ok, %{"responseCode" => "2001", "params" => %{"state" => "APPROVED"}} = resp} ->
        {:ok, %{provider_txn_id: Map.fetch!(resp, "transactionId"), state: :approved}}

      {:ok, %{"responseCode" => "5309"}} ->
        {:error, :timeout}

      {:ok, %{"responseCode" => "5306"}} ->
        {:error, :rejected}

      {:ok, %{"errorCode" => "E10205"}} ->
        {:error, :insufficient_funds}

      {:ok, %{"responseCode" => "401" <> _}} ->
        {:error, :invalid_credentials}

      {:ok, %{"responseCode" => code}} ->
        {:error, {:provider, code}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl Provider
  def refund(credentials, provider_txn_id, amount) do
    body =
      envelope("HPP_REFUNDPURCHASE", Ecto.UUID.generate(), %{
        merchantUid: credentials.merchant_uid,
        apiUserId: credentials.api_user_id,
        apiKey: credentials.api_key,
        transactionId: provider_txn_id,
        amount: decimal_amount(amount),
        currency: to_string(amount.currency)
      })

    case post(body) do
      {:ok, %{"responseCode" => "2001"} = resp} ->
        {:ok, %{provider_refund_id: Map.fetch!(resp, "transactionId")}}

      {:ok, %{"responseCode" => code}} ->
        {:error, {:provider, code}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl Provider
  def lookup(credentials, reference_id) do
    body =
      envelope("HPP_GETTRANINFO", Ecto.UUID.generate(), %{
        merchantUid: credentials.merchant_uid,
        apiUserId: credentials.api_user_id,
        apiKey: credentials.api_key,
        referenceId: reference_id
      })

    case post(body) do
      {:ok, %{"params" => %{"state" => "APPROVED"}} = resp} ->
        {:ok, %{provider_txn_id: resp["transactionId"], state: :approved}}

      {:ok, %{"params" => %{"state" => state}}} when state in ["PENDING", "SUBMITTED"] ->
        {:ok, %{provider_txn_id: nil, state: :pending}}

      {:ok, %{"params" => %{"state" => _failed}}} ->
        {:ok, %{provider_txn_id: nil, state: :failed}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  HMAC-SHA256 over `{timestamp}.{event_id}.{raw_body}` (library-docs.md);
  rejects a signature older than 5 minutes (replay protection, matches
  the docs' own stated staleness window). The secret is the platform's
  single registered webhook secret (`config :tabletap, :waafipay,
  webhook_secret`) — WaafiPay's webhook registration is platform-level,
  not per-venue, so one secret verifies every venue's callbacks.
  """
  @impl Provider
  def verify_callback(raw_body, headers) do
    with {:ok, timestamp} <- fetch_header(headers, "x-webhook-timestamp"),
         {:ok, event_id} <- fetch_header(headers, "x-webhook-event-id"),
         {:ok, signature} <- fetch_header(headers, "x-webhook-signature"),
         true <- fresh?(timestamp),
         true <- valid_signature?(timestamp, event_id, raw_body, signature),
         {:ok, payload} <- Jason.decode(raw_body) do
      {:ok, payload}
    else
      _ -> :error
    end
  end

  ## Request plumbing

  defp envelope(service_name, request_id, service_params) do
    %{
      schemaVersion: @schema_version,
      requestId: request_id,
      timestamp: DateTime.to_iso8601(DateTime.utc_now()),
      channelName: @channel_name,
      serviceName: service_name,
      serviceParams: service_params
    }
  end

  defp post(body) do
    case Req.post(api_url(), json: body, receive_timeout: :timer.minutes(6)) do
      {:ok, %Req.Response{status: status, body: resp_body}} when status in 200..299 ->
        {:ok, resp_body}

      {:ok, %Req.Response{status: status}} ->
        {:error, {:http_status, status}}

      {:error, exception} ->
        {:error, {:request_failed, Exception.message(exception)}}
    end
  end

  defp api_url, do: Application.fetch_env!(:tabletap, :waafipay) |> Keyword.fetch!(:api_url)

  defp webhook_secret,
    do: Application.fetch_env!(:tabletap, :waafipay) |> Keyword.fetch!(:webhook_secret)

  # decimal string, never a float or minor units (library-docs.md).
  defp decimal_amount(%Money{} = money), do: money |> Money.to_decimal() |> Decimal.to_string()

  defp fetch_header(headers, key) do
    case Map.get(headers, key) do
      nil -> :error
      value -> {:ok, value}
    end
  end

  defp fresh?(timestamp_string) do
    case Integer.parse(timestamp_string) do
      {seconds, ""} -> abs(System.system_time(:second) - seconds) <= 300
      _ -> false
    end
  end

  defp valid_signature?(timestamp, event_id, raw_body, given_signature) do
    signed = "#{timestamp}.#{event_id}.#{raw_body}"

    expected =
      :crypto.mac(:hmac, :sha256, webhook_secret(), signed) |> Base.encode16(case: :lower)

    Plug.Crypto.secure_compare(expected, String.downcase(given_signature))
  end
end
