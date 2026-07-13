defmodule TabletapWeb.Public.WaafiPayWebhookController do
  @moduledoc """
  Inbound WaafiPay callback for `authorization`/`refund` events
  (build-plan.md Feature 09; library-docs.md "callback controller: verify
  HMAC-SHA256 signature → insert-first on provider_txn_id → enqueue Oban
  job → 200"). Never processes the payment inline — always enqueues
  `Workers.ProcessCallback` and returns immediately, since the actual
  confirmation work runs through the same shared, idempotent path
  (`Payments.confirm_approved/2`/`confirm_failed/1`) the charge worker
  and the reconciliation poller also use.

  WaafiPay does **not** retry a failed delivery — this controller is an
  optimization, never the mechanism; the poller is the guaranteed path
  (code-standards.md "Callbacks are an optimization, never the
  mechanism").
  """
  use TabletapWeb, :controller

  alias Tabletap.Payments.Adapters.WaafiPay
  alias Tabletap.Payments.Workers.ProcessCallback

  def create(conn, _params) do
    raw_body = conn.assigns[:raw_body] || ""
    headers = Map.new(conn.req_headers)

    case WaafiPay.verify_callback(raw_body, headers) do
      {:ok, payload} ->
        %{"payload" => payload} |> ProcessCallback.new() |> Oban.insert()
        send_resp(conn, 200, "")

      :error ->
        send_resp(conn, 401, "")
    end
  end
end
