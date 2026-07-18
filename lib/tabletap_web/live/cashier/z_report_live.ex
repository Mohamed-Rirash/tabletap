defmodule TabletapWeb.Cashier.ZReportLive do
  @moduledoc """
  End-of-day close (build-plan.md Feature 15; design-qa.md's Gap
  Analysis "End-of-day close (Z-report)"). Shows a live preview of the
  business day's numbers (`Payments.z_report_preview/2`) with one
  editable "counted cash" field per cashier who took cash that day;
  closing (`Payments.close_z_report/3`) freezes those numbers — a
  previously-closed day renders the stored snapshot instead, read-only
  (Q38 "the original close stays visible as closed").
  """
  use TabletapWeb, :live_view

  alias Tabletap.{Payments, Tenants}

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <div class="mx-auto max-w-2xl">
        <div class="flex items-center justify-between mb-4">
          <h1 class="text-xl font-bold">
            {gettext("Z-report — %{date}", date: Date.to_string(@business_date))}
          </h1>
          <.link navigate={~p"/pos"} class="btn btn-outline btn-sm">{gettext("Back to register")}</.link>
        </div>

        <.closed_report :if={@report} report={@report} memberships={@memberships} locale={@locale} />

        <.open_preview
          :if={!@report}
          preview={@preview}
          memberships={@memberships}
          locale={@locale}
        />
      </div>
    </Layouts.app>
    """
  end

  attr :report, :any, required: true
  attr :memberships, :map, required: true
  attr :locale, :string, required: true

  defp closed_report(assigns) do
    assigns = assign(assigns, :totals, totals_from_storage(assigns.report.totals))

    ~H"""
    <div class="rounded-box bg-base-100 border border-base-300 p-5 space-y-4">
      <span class="badge badge-success">{gettext("Closed")}</span>

      <.totals_grid totals={@totals} locale={@locale} />

      <div>
        <p class="font-semibold mb-2">{gettext("Cash reconciliation")}</p>
        <div
          :for={count <- @report.cash_counts}
          class="flex items-center justify-between py-1 text-sm border-b border-base-200 last:border-0"
        >
          <span>{cashier_label(@memberships, count.membership_id)}</span>
          <span class="flex items-center gap-3">
            <.money amount={count.expected_cash} locale={@locale} class="text-base-content/60" />
            <.money amount={count.counted_cash} locale={@locale} class="font-medium" />
            <span class={["font-semibold", variance_class(count.variance)]}>
              <.money amount={count.variance} locale={@locale} />
            </span>
          </span>
        </div>
      </div>
    </div>
    """
  end

  attr :preview, :any, required: true
  attr :memberships, :map, required: true
  attr :locale, :string, required: true

  defp open_preview(assigns) do
    ~H"""
    <form
      id="close-report-form"
      phx-submit="close_report"
      class="rounded-box bg-base-100 border border-base-300 p-5 space-y-4"
    >
      <.totals_grid totals={@preview} locale={@locale} />

      <div>
        <p class="font-semibold mb-2">
          {gettext("Cash reconciliation — enter what's actually in the drawer")}
        </p>
        <p :if={@preview.cash_counts == %{}} class="text-sm text-base-content/50">
          {gettext("No cash payments recorded yet today.")}
        </p>
        <div
          :for={{membership_id, expected} <- @preview.cash_counts}
          class="flex items-center justify-between gap-3 py-2"
        >
          <span class="text-sm flex-1">{cashier_label(@memberships, membership_id)}</span>
          <span class="text-sm text-base-content/60">
            {gettext("Expected")} <.money amount={expected} locale={@locale} />
          </span>
          <input
            type="text"
            inputmode="decimal"
            name={"counted[#{membership_id}]"}
            placeholder="0.00"
            class="input input-sm w-28"
          />
        </div>
      </div>

      <button type="submit" class="btn btn-primary w-full h-12">{gettext("Close business day")}</button>
    </form>
    """
  end

  attr :totals, :map, required: true
  attr :locale, :string, required: true

  defp totals_grid(assigns) do
    ~H"""
    <dl class="grid grid-cols-2 gap-3 text-sm">
      <div>
        <dt class="text-base-content/60">{gettext("Orders")}</dt>
        <dd class="font-semibold">{@totals.order_count}</dd>
      </div>
      <div>
        <dt class="text-base-content/60">{gettext("Net revenue")}</dt>
        <dd class="font-semibold"><.money amount={@totals.net_revenue} locale={@locale} /></dd>
      </div>
      <div>
        <dt class="text-base-content/60">{gettext("Discounts")}</dt>
        <dd class="font-semibold"><.money amount={@totals.discount_total} locale={@locale} /></dd>
      </div>
      <div>
        <dt class="text-base-content/60">{gettext("Refunds")}</dt>
        <dd class="font-semibold"><.money amount={@totals.refund_total} locale={@locale} /></dd>
      </div>
    </dl>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    scope = socket.assigns.current_scope
    business_date = Tenants.business_date(scope.venue)

    {:ok,
     socket
     |> assign(:hide_utility_bar, true)
     |> assign(:locale, scope.venue.locale)
     |> assign(:business_date, business_date)
     |> load_report()}
  end

  @impl true
  def handle_event("close_report", params, socket) do
    scope = socket.assigns.current_scope
    counted = Map.get(params, "counted", %{})

    case parse_counted_cash(counted, scope.venue.currency) do
      {:ok, counted_by_membership} ->
        do_close_report(socket, scope, counted_by_membership)

      :error ->
        {:noreply,
         put_flash(
           socket,
           :error,
           gettext("That doesn't look like a valid cash amount — please re-enter it.")
         )}
    end
  end

  # A cashier can type anything into a "counted cash" field — a stray
  # letter, a comma, a paste-in typo. `Decimal.parse/1` returns `:error`
  # for any of those, so this must never hard-match, unlike
  # `money_from_storage/1` below (which only ever reads back data this
  # same module wrote).
  defp parse_counted_cash(counted, currency) do
    counted
    |> Enum.filter(fn {_id, v} -> v != "" end)
    |> Enum.reduce_while({:ok, %{}}, fn {id, v}, {:ok, acc} ->
      case Decimal.parse(v) do
        {decimal, ""} -> {:cont, {:ok, Map.put(acc, id, Money.new!(currency, decimal))}}
        _ -> {:halt, :error}
      end
    end)
  end

  defp do_close_report(socket, scope, counted_by_membership) do
    case Payments.close_z_report(scope, socket.assigns.business_date, counted_by_membership) do
      {:ok, _report} ->
        {:noreply, socket |> put_flash(:info, gettext("Business day closed.")) |> load_report()}

      {:error, _changeset} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           gettext("Couldn't close — this business day may already be closed.")
         )}
    end
  end

  defp load_report(socket) do
    scope = socket.assigns.current_scope
    business_date = socket.assigns.business_date

    case Payments.get_z_report(scope, business_date) do
      nil ->
        preview = Payments.z_report_preview(scope, business_date)
        memberships = memberships_for(scope, Map.keys(preview.cash_counts))

        socket
        |> assign(:report, nil)
        |> assign(:preview, preview)
        |> assign(:memberships, memberships)

      report ->
        ids = Enum.map(report.cash_counts, & &1.membership_id)
        memberships = memberships_for(scope, ids)

        socket
        |> assign(:report, report)
        |> assign(:preview, nil)
        |> assign(:memberships, memberships)
    end
  end

  defp memberships_for(_scope, []), do: %{}

  defp memberships_for(scope, ids),
    do: scope |> Tenants.list_memberships(ids) |> Map.new(&{&1.id, &1})

  defp cashier_label(memberships, membership_id) do
    case Map.get(memberships, membership_id) do
      nil -> gettext("Unknown")
      membership -> membership.user.email
    end
  end

  defp variance_class(variance) do
    zero = Money.new!(variance.currency, 0)

    cond do
      Money.compare!(variance, zero) == :eq -> "text-success"
      Money.compare!(variance, zero) == :lt -> "text-error"
      true -> "text-warning"
    end
  end

  # The stored jsonb blob (`Payments.close_z_report/3`'s
  # `money_for_storage/1`) is raw decimal + currency strings, not a real
  # `Money` struct — jsonb round-trips as plain maps, and storage
  # deliberately avoids `Money.to_string!/2` (the "so"-locale landmine
  # already flagged in progress-tracker.md). Reconstruct here, once, for
  # display.
  defp totals_from_storage(totals) do
    %{
      order_count: totals["order_count"],
      net_revenue: money_from_storage(totals["net_revenue"]),
      discount_total: money_from_storage(totals["discount_total"]),
      refund_total: money_from_storage(totals["refund_total"])
    }
  end

  defp money_from_storage(%{"amount" => amount, "currency" => currency}) do
    {decimal, _} = Decimal.parse(amount)
    Money.new!(currency, decimal)
  end
end
