defmodule TabletapWeb.Manager.BillingLive do
  @moduledoc """
  Owner-facing billing (build-plan.md Feature 19; role-features.md
  "SaaS subscription" — owner back-office, same `:require_owner`
  live_session as `PaymentSettingsLive`). Current plan + trial status,
  a monthly itemized preview (plan price + accrued-but-unsettled
  `platform_fee_ledger` fees — read-only: no charge happens here, that's
  `Tabletap.Billing`'s job, not yet built), a plan-change action
  (upgrade unrestricted; downgrade blocked while venue count exceeds
  the target plan's cap, per `Tenants.change_plan/2`), and a minimal
  "add venue" form (`Tenants.create_venue/2` — the only self-serve way
  to create a second venue anywhere in the app; nothing else builds
  this).
  """
  use TabletapWeb, :live_view

  alias Tabletap.{Payments, Plans, Tenants}

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.manager
      flash={@flash}
      current_scope={@current_scope}
      active_nav={:billing}
      venues={@venues}
    >
      <h1 class="text-2xl font-bold mb-2">{gettext("Billing")}</h1>

      <.trial_banner org={@current_scope.org} />

      <div class="rounded-box bg-base-100 shadow-sm p-5 mb-6">
        <div class="flex items-center justify-between flex-wrap gap-4">
          <div>
            <p class="font-medium">{Plans.name(@current_scope.org.plan)}</p>
            <p class="text-sm text-base-content/60">
              <.money amount={Plans.monthly_price(@current_scope.org.plan, length(@venues))} />
              / {gettext("month")} · {gettext("%{pct}% per-order fee",
                pct:
                  @current_scope.org.plan
                  |> Plans.fee_rate()
                  |> Decimal.mult(100)
                  |> Decimal.to_string()
              )}
            </p>
          </div>
          <span class="badge badge-outline">{subscription_status_label(
            @current_scope.org.subscription_status
          )}</span>
        </div>

        <div class="divider my-3" />

        <h2 class="font-medium text-sm mb-2">{gettext("This period's itemized preview")}</h2>
        <ul class="text-sm space-y-1">
          <li class="flex justify-between">
            <span>{Plans.name(@current_scope.org.plan)} {gettext("plan")}</span>
            <span class="tabular-nums">
              <.money amount={Plans.monthly_price(@current_scope.org.plan, length(@venues))} />
            </span>
          </li>
          <li :for={row <- @unsettled_fees} class="flex justify-between">
            <span>{gettext("Accrued per-order fees (%{currency})", currency: row.currency)}</span>
            <span class="tabular-nums"><.money amount={row.amount} /></span>
          </li>
        </ul>
        <p class="text-xs text-base-content/50 mt-3">
          {gettext(
            "A preview only — collection isn't automated yet. No charge happens from this screen."
          )}
        </p>
      </div>

      <div class="rounded-box bg-base-100 shadow-sm p-5 mb-6">
        <h2 class="font-medium mb-3">{gettext("Change plan")}</h2>
        <form id="change-plan-form" phx-submit="change_plan" class="flex items-center gap-2 flex-wrap">
          <select name="plan" class="select select-sm">
            <option
              :for={tier <- Plans.tiers()}
              value={tier}
              selected={tier == @current_scope.org.plan}
            >
              {Plans.name(tier)}
            </option>
          </select>
          <button type="submit" class="btn btn-sm btn-primary">{gettext("Change plan")}</button>
        </form>
      </div>

      <div class="rounded-box bg-base-100 shadow-sm p-5">
        <div class="flex items-center justify-between mb-3">
          <h2 class="font-medium">{gettext("Venues")}</h2>
          <span class="text-xs text-base-content/50">
            {length(@venues)} / {Plans.venue_cap(@current_scope.org.plan)}
          </span>
        </div>
        <ul class="text-sm space-y-1 mb-4">
          <li :for={venue <- @venues}>{venue.name}</li>
        </ul>

        <form
          :if={length(@venues) < Plans.venue_cap(@current_scope.org.plan)}
          id="add-venue-form"
          phx-submit="add_venue"
          class="flex items-center gap-2 flex-wrap"
        >
          <input
            type="text"
            name="name"
            placeholder={gettext("Venue name")}
            class="input input-sm"
            required
          />
          <select name="city" class="select select-sm">
            <option :for={{city, _currency, _tz} <- Tenants.city_options()} value={city}>
              {city}
            </option>
          </select>
          <button type="submit" class="btn btn-sm btn-outline">{gettext("Add venue")}</button>
        </form>
        <p
          :if={length(@venues) >= Plans.venue_cap(@current_scope.org.plan)}
          class="text-sm text-base-content/60"
        >
          {gettext("Your %{plan} plan allows %{cap} venue(s) — upgrade to add more.",
            plan: Plans.name(@current_scope.org.plan),
            cap: Plans.venue_cap(@current_scope.org.plan)
          )}
        </p>
      </div>
    </Layouts.manager>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    scope = socket.assigns.current_scope

    {:ok,
     socket
     |> assign(:hide_utility_bar, true)
     |> assign(:venues, Tenants.list_venues(scope))
     |> assign(:unsettled_fees, Payments.unsettled_platform_fees_by_currency(scope))}
  end

  @impl true
  def handle_event("change_plan", %{"plan" => plan}, socket) do
    scope = socket.assigns.current_scope

    case Tenants.change_plan(scope, String.to_existing_atom(plan)) do
      {:ok, org} ->
        {:noreply,
         socket
         |> assign(:current_scope, %{scope | org: org})
         |> put_flash(:info, gettext("Plan changed."))}

      {:error, :venue_cap_exceeded} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           gettext(
             "Can't downgrade — you have more venues than that plan allows. Deactivate venues first."
           )
         )}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, gettext("Couldn't change plan."))}
    end
  rescue
    ArgumentError -> {:noreply, put_flash(socket, :error, gettext("Couldn't change plan."))}
  end

  def handle_event("add_venue", %{"name" => name, "city" => city}, socket) do
    scope = socket.assigns.current_scope

    case Tenants.create_venue(scope, %{"name" => name, "city" => city}) do
      {:ok, venue} ->
        {:noreply,
         socket
         |> assign(:venues, Tenants.list_venues(scope))
         |> put_flash(:info, gettext("%{name} added.", name: venue.name))}

      {:error, :venue_cap_reached} ->
        {:noreply, put_flash(socket, :error, gettext("Your plan doesn't allow another venue."))}

      {:error, %Ecto.Changeset{}} ->
        {:noreply, put_flash(socket, :error, gettext("Couldn't add that venue."))}
    end
  end

  defp subscription_status_label(:trialing), do: gettext("Trialing")
  defp subscription_status_label(:active), do: gettext("Active")
  defp subscription_status_label(:past_due), do: gettext("Past due")
  defp subscription_status_label(:canceled), do: gettext("Canceled")
end
