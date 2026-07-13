defmodule Tabletap.Payments.Workers.ProcessCallback do
  @moduledoc """
  Resolves an already-HMAC-verified WaafiPay callback payload
  (build-plan.md Feature 09) — enqueued by
  `TabletapWeb.Public.WaafiPayWebhookController`, never run inline in the
  controller. Looks the payment up by our own `requestId` (echoed back
  by WaafiPay — library-docs.md "requestId = our payments-row id, making
  charge retries idempotent on both sides"), then funnels through the
  same shared, idempotent `Payments.confirm_approved/2`/`confirm_failed/1`
  path the charge worker and the reconciliation poller also use — a
  duplicate or late-arriving callback for an already-resolved payment is
  a safe no-op, not a double-charge.

  An unresolvable payload (unknown/missing `requestId`, or a `payment_id`
  that was never issued by us) is silently dropped rather than retried —
  the reconciliation poller is the guaranteed confirmation path anyway,
  so a malformed or spoofed-shaped callback isn't this worker's problem
  to chase.
  """
  use Oban.Worker, queue: :webhooks, max_attempts: 5

  alias Tabletap.{Payments, Repo, Tenants}

  @approved_states ["APPROVED"]
  @terminal_failure_states ["FAILED", "DECLINED", "CANCELED", "EXPIRED", "TIMEOUT"]

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"payload" => payload}}) do
    with {:ok, payment_id} <- fetch_payment_id(payload),
         %{} = payment <- Tenants.get_payment_by_id(payment_id) do
      Repo.put_org_id(payment.org_id)
      dispatch(payment_id, payload)
    else
      _ -> :ok
    end
  end

  defp fetch_payment_id(%{"requestId" => id}) when is_binary(id), do: {:ok, id}
  defp fetch_payment_id(_payload), do: :error

  defp dispatch(payment_id, %{"params" => %{"state" => state}} = payload)
       when state in @approved_states do
    case Payments.confirm_approved(payment_id, payload["transactionId"]) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp dispatch(payment_id, %{"params" => %{"state" => state}})
       when state in @terminal_failure_states do
    case Payments.confirm_failed(payment_id) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp dispatch(_payment_id, _payload), do: :ok
end
