defmodule TabletapWeb.Public.WaafiPayWebhookControllerTest do
  use TabletapWeb.ConnCase, async: true
  use Oban.Testing, repo: Tabletap.ObanRepo

  alias Tabletap.Payments.Workers.ProcessCallback

  # config/test.exs pins this so signatures here are deterministic.
  @secret Application.compile_env(:tabletap, :waafipay)[:webhook_secret]

  defp sign(timestamp, event_id, body) do
    :crypto.mac(:hmac, :sha256, @secret, "#{timestamp}.#{event_id}.#{body}")
    |> Base.encode16(case: :lower)
  end

  test "a validly signed callback enqueues ProcessCallback and returns 200", %{conn: conn} do
    request_id = Ecto.UUID.generate()
    body = Jason.encode!(%{"requestId" => request_id, "params" => %{"state" => "APPROVED"}})

    timestamp = System.system_time(:second)
    signature = sign(timestamp, "evt-1", body)

    conn =
      conn
      |> put_req_header("content-type", "application/json")
      |> put_req_header("x-webhook-timestamp", to_string(timestamp))
      |> put_req_header("x-webhook-event-id", "evt-1")
      |> put_req_header("x-webhook-signature", signature)
      |> post(~p"/webhooks/waafipay", body)

    assert conn.status == 200
    assert_enqueued(worker: ProcessCallback, args: %{"payload" => %{"requestId" => request_id}})
  end

  test "an incorrectly signed callback is rejected with 401, never enqueued", %{conn: conn} do
    request_id = Ecto.UUID.generate()
    body = Jason.encode!(%{"requestId" => request_id})

    conn =
      conn
      |> put_req_header("content-type", "application/json")
      |> put_req_header("x-webhook-timestamp", to_string(System.system_time(:second)))
      |> put_req_header("x-webhook-event-id", "evt-1")
      |> put_req_header("x-webhook-signature", "not-a-real-signature")
      |> post(~p"/webhooks/waafipay", body)

    assert conn.status == 401

    # Scoped to this test's own request_id, not just the worker name —
    # Tabletap.ObanRepo isn't wrapped in the per-test SQL Sandbox
    # (lib/tabletap/oban_repo.ex — it can't be, Oban's own tables aren't
    # tenant-owned), so a job legitimately enqueued by another test in
    # this same file is still sitting in the real jobs table and would
    # false-positive an unscoped refute_enqueued(worker: ProcessCallback).
    refute_enqueued(worker: ProcessCallback, args: %{"payload" => %{"requestId" => request_id}})
  end

  test "a missing signature header is rejected with 401", %{conn: conn} do
    body = Jason.encode!(%{"requestId" => Ecto.UUID.generate()})

    conn =
      conn
      |> put_req_header("content-type", "application/json")
      |> post(~p"/webhooks/waafipay", body)

    assert conn.status == 401
  end
end
