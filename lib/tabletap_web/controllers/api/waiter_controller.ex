defmodule TabletapWeb.Api.WaiterController do
  @moduledoc """
  build-plan.md Feature 23 Commit 4 — `POST /api/v1/waiter/orders/:id/
  accept` and `/served`, wrapping `Ordering.accept_order/2` and
  `Ordering.confirm_served_by_scan/3` exactly as `Waiter.QueueLive`'s
  own event handlers do. `conn.assigns.current_scope` (built by the
  `:require_api_waiter` pipeline's `assign_scope`/`require_api_role`
  plugs) always carries a real `membership` here — the role gate
  guarantees it.
  """
  use TabletapWeb, :controller

  alias Tabletap.Ordering
  alias TabletapWeb.Api.{Params, Serializers}

  def accept(conn, %{"id" => id}) do
    with_order(conn, id, fn scope, order ->
      case Ordering.accept_order(scope, order) do
        {:ok, order} -> render_order(conn, scope, order)
        {:error, reason} -> error(conn, :unprocessable_entity, reason)
      end
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
