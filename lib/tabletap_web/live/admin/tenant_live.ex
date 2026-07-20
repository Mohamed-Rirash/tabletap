defmodule TabletapWeb.Admin.TenantLive do
  @moduledoc """
  Platform-admin per-tenant detail (build-plan.md Feature 19) — plan
  and subscription status, cash share per venue (design-qa.md Q24),
  and billing history. Strictly read-only: "impersonation guard
  (read-only)" means this page lets an admin *look at* a tenant's
  data, never act as that tenant — there is no write path here.
  """
  use TabletapWeb, :live_view

  alias Tabletap.Admin
  alias Tabletap.Plans

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <.link navigate={~p"/admin"} class="text-sm text-base-content/60">&larr; Tenants</.link>
      <h1 class="text-2xl font-bold mt-2 mb-4">{@org.name}</h1>

      <div class="rounded-box bg-base-100 shadow-sm p-5 mb-6">
        <p><span class="text-base-content/60">Plan:</span> {Plans.name(@org.plan)}</p>
        <p><span class="text-base-content/60">Status:</span> {@org.subscription_status}</p>
        <p :if={@org.subscription_status == :trialing}>
          <span class="text-base-content/60">Trial ends:</span> {@org.trial_ends_at}
        </p>
        <p>
          <span class="text-base-content/60">Billing wallet:</span> {@org.billing_wallet_msisdn ||
            "not set"}
        </p>
      </div>

      <h2 class="font-medium mb-2">Cash share per venue</h2>
      <table class="table table-sm mb-6">
        <thead>
          <tr>
            <th>Venue</th>
            <th>Cash</th>
            <th>Total</th>
            <th>Cash %</th>
          </tr>
        </thead>
        <tbody>
          <tr :for={row <- @cash_share}>
            <td>{row.venue.name}</td>
            <td class="tabular-nums">{row.cash_count}</td>
            <td class="tabular-nums">{row.total_count}</td>
            <td class="tabular-nums">{cash_share_label(row.cash_share_pct)}</td>
          </tr>
          <tr :if={@cash_share == []}>
            <td colspan="4" class="text-center text-base-content/50 py-4">No venues.</td>
          </tr>
        </tbody>
      </table>

      <h2 class="font-medium mb-2">Billing history</h2>
      <table class="table table-sm">
        <thead>
          <tr>
            <th>Period</th>
            <th>Plan</th>
            <th>Amount</th>
            <th>Status</th>
          </tr>
        </thead>
        <tbody>
          <tr :for={invoice <- @invoices}>
            <td>{invoice.period_start} &ndash; {invoice.period_end}</td>
            <td>{Plans.name(invoice.plan)}</td>
            <td class="tabular-nums"><.money amount={invoice.plan_amount} /></td>
            <td>{invoice.status}</td>
          </tr>
          <tr :if={@invoices == []}>
            <td colspan="4" class="text-center text-base-content/50 py-4">No invoices yet.</td>
          </tr>
        </tbody>
      </table>
    </Layouts.app>
    """
  end

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    case Admin.get_tenant(id) do
      nil ->
        {:ok,
         socket
         |> put_flash(:error, "Tenant not found.")
         |> redirect(to: ~p"/admin")}

      org ->
        {:ok,
         socket
         |> assign(:org, org)
         |> assign(:cash_share, Admin.cash_share_by_venue(org))
         |> assign(:invoices, Admin.list_invoices(org))}
    end
  end

  defp cash_share_label(nil), do: "—"
  defp cash_share_label(pct), do: "#{Decimal.round(pct, 1)}%"
end
