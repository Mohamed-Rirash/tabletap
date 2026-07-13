defmodule Tabletap.Payments.Adapters.WaafiPayTest do
  @moduledoc """
  `WaafiPay.verify_callback/2` — pure HMAC-SHA256 verification logic, no
  network involved (code-standards.md: no test hits the real WaafiPay
  API). `charge/2`/`refund/3`/`lookup/2` themselves are exercised only
  through `Payments.ProviderMock` elsewhere — this adapter's response-
  shape mapping is covered by reading the code against the research
  note's documented codes, not by a live call.
  """
  use ExUnit.Case, async: true

  alias Tabletap.Payments.Adapters.WaafiPay

  # config/test.exs pins this secret so these tests are deterministic.
  @secret Application.compile_env(:tabletap, :waafipay)[:webhook_secret]

  defp sign(timestamp, event_id, body) do
    :crypto.mac(:hmac, :sha256, @secret, "#{timestamp}.#{event_id}.#{body}")
    |> Base.encode16(case: :lower)
  end

  defp headers(timestamp, event_id, signature) do
    %{
      "x-webhook-timestamp" => to_string(timestamp),
      "x-webhook-event-id" => event_id,
      "x-webhook-signature" => signature
    }
  end

  test "accepts a correctly signed, fresh callback and decodes its JSON body" do
    body = Jason.encode!(%{"requestId" => "pay-123", "params" => %{"state" => "APPROVED"}})
    timestamp = System.system_time(:second)
    signature = sign(timestamp, "evt-1", body)

    assert {:ok, payload} = WaafiPay.verify_callback(body, headers(timestamp, "evt-1", signature))
    assert payload["requestId"] == "pay-123"
  end

  test "rejects a tampered body (signature no longer matches)" do
    body = Jason.encode!(%{"requestId" => "pay-123"})
    timestamp = System.system_time(:second)
    signature = sign(timestamp, "evt-1", body)

    tampered_body = Jason.encode!(%{"requestId" => "pay-999"})

    assert :error =
             WaafiPay.verify_callback(tampered_body, headers(timestamp, "evt-1", signature))
  end

  test "rejects a signature computed with the wrong secret" do
    body = Jason.encode!(%{"requestId" => "pay-123"})
    timestamp = System.system_time(:second)

    bad_signature =
      :crypto.mac(:hmac, :sha256, "wrong-secret", "#{timestamp}.evt-1.#{body}")
      |> Base.encode16(case: :lower)

    assert :error = WaafiPay.verify_callback(body, headers(timestamp, "evt-1", bad_signature))
  end

  test "rejects a stale timestamp (older than 5 minutes)" do
    body = Jason.encode!(%{"requestId" => "pay-123"})
    stale_timestamp = System.system_time(:second) - 301
    signature = sign(stale_timestamp, "evt-1", body)

    assert :error = WaafiPay.verify_callback(body, headers(stale_timestamp, "evt-1", signature))
  end

  test "rejects a request missing a required header" do
    body = Jason.encode!(%{"requestId" => "pay-123"})
    timestamp = System.system_time(:second)
    signature = sign(timestamp, "evt-1", body)

    incomplete = headers(timestamp, "evt-1", signature) |> Map.delete("x-webhook-event-id")

    assert :error = WaafiPay.verify_callback(body, incomplete)
  end

  test "the signature check is case-insensitive on hex encoding" do
    body = Jason.encode!(%{"requestId" => "pay-123"})
    timestamp = System.system_time(:second)
    signature = sign(timestamp, "evt-1", body) |> String.upcase()

    assert {:ok, _payload} =
             WaafiPay.verify_callback(body, headers(timestamp, "evt-1", signature))
  end
end
