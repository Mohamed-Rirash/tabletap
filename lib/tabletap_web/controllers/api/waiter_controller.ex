defmodule TabletapWeb.Api.WaiterController do
  @moduledoc """
  build-plan.md Feature 23 Commit 4 (accept/served) and Feature 25
  (shift toggle, queue, claim board, claim, unserveable) — every action
  a thin wrapper over `Ordering`/`Staffing`, exactly as `Waiter.
  QueueLive`'s own event handlers do. `conn.assigns.current_scope`
  (built by the `:require_api_waiter` pipeline's `assign_scope`/
  `require_api_role` plugs) always carries a real `membership` here —
  the role gate guarantees it.
  """
  use TabletapWeb, :controller

  alias Tabletap.{Ordering, Staffing}
  alias TabletapWeb.Api.{Params, Serializers}

  @doc "Clocks the current membership in for a shift — wraps `Staffing.clock_in/1`."
  def clock_in(conn, _params) do
    case Staffing.clock_in(conn.assigns.current_scope) do
      {:ok, _shift} -> send_resp(conn, :no_content, "")
      {:error, reason} -> error(conn, :unprocessable_entity, reason)
    end
  end

  @doc "Clocks the current membership out — wraps `Staffing.clock_out/1`."
  def clock_out(conn, _params) do
    case Staffing.clock_out(conn.assigns.current_scope) do
      {:ok, _shift} -> send_resp(conn, :no_content, "")
      {:error, reason} -> error(conn, :unprocessable_entity, reason)
    end
  end

  @doc "The waiter's own assigned FIFO queue — wraps `Ordering.list_waiter_queue/1`."
  def queue(conn, _params) do
    scope = conn.assigns.current_scope
    json(conn, %{orders: Enum.map(Ordering.list_waiter_queue(scope), &queue_row(scope, &1))})
  end

  @doc "The venue-wide claim board — wraps `Ordering.list_claim_board/1`."
  def claim_board(conn, _params) do
    scope = conn.assigns.current_scope
    json(conn, %{orders: Enum.map(Ordering.list_claim_board(scope), &queue_row(scope, &1))})
  end

  defp queue_row(scope, order),
    do: Serializers.kitchen_order(order, Ordering.estimated_minutes(scope, order))

  def accept(conn, %{"id" => id}) do
    with_order(conn, id, fn scope, order ->
      case Ordering.accept_order(scope, order) do
        {:ok, order} -> render_order(conn, scope, order)
        {:error, reason} -> error(conn, :unprocessable_entity, reason)
      end
    end)
  end

  @doc "First-tap-wins claim of an unassigned order — wraps `Ordering.claim_order/2`."
  def claim(conn, %{"id" => id}) do
    scope = conn.assigns.current_scope

    with {:ok, id} <- Params.cast_uuid(id),
         {:ok, order} <- Ordering.claim_order(scope, id) do
      render_order(conn, scope, order)
    else
      :error -> error(conn, :not_found, "order_not_found")
      {:error, reason} -> error(conn, :unprocessable_entity, reason)
    end
  end

  @doc "Flags a ready order the waiter can't hand off (\"can't find customer\") — wraps `Ordering.mark_unserveable/2`."
  def unserveable(conn, %{"id" => id}) do
    with_order(conn, id, fn scope, order ->
      {:ok, order} = Ordering.mark_unserveable(scope, order)
      render_order(conn, scope, order)
    end)
  end

  def served(conn, %{"id" => id, "scanned_value" => scanned_value}) do
    with_order(conn, id, fn scope, order ->
      case Ordering.confirm_served_by_scan(scope, order, scanned_value) do
        {:ok, order} -> render_order(conn, scope, order)
        {:error, reason} -> error(conn, :unprocessable_entity, reason)
      end
    end)
  end

  defp with_order(conn, id, fun) do
    scope = conn.assigns.current_scope

    with {:ok, id} <- Params.cast_uuid(id),
         order when not is_nil(order) <- Ordering.get_order(scope, id) do
      fun.(scope, order)
    else
      _ -> error(conn, :not_found, "order_not_found")
    end
  end

  defp render_order(conn, scope, order) do
    eta = Ordering.estimated_minutes(scope, order)
    json(conn, Serializers.order(order, eta, nil))
  end

  defp error(conn, status, reason) do
    conn |> put_status(status) |> json(%{error: to_string(reason)})
  end
end
