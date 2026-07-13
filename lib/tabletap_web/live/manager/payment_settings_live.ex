defmodule TabletapWeb.Manager.PaymentSettingsLive do
  @moduledoc """
  Wallet merchant credentials (build-plan.md Feature 09; role-features.md
  "Payment account" — owner back-office, not manager: the route this
  mounts under is `:require_owner`, not `:require_manager`). The owner
  pastes in WaafiPay merchant credentials from the offline paperwork,
  then verifies them — `charges_enabled` only flips true after a real
  successful `Payments.verify_credentials/2` round-trip, never on save
  alone (`Tenants.Venue.waafipay_credentials_changeset/2`'s own rule).
  """
  use TabletapWeb, :live_view

  alias Tabletap.{Payments, Tenants}
  alias Tabletap.Tenants.Venue

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.manager
      flash={@flash}
      current_scope={@current_scope}
      active_nav={:payments}
      venues={@venues}
    >
      <h1 class="text-2xl font-bold mb-2">{gettext("Payment account")}</h1>
      <p class="text-sm text-base-content/60 mb-6 max-w-prose">
        {gettext(
          "WaafiPay merchant credentials for this venue, from your offline registration with WaafiPay. Customer payments land directly in your own merchant account — we never hold your money."
        )}
      </p>

      <div class="rounded-box bg-base-100 shadow-sm p-5 mb-6 flex items-center justify-between gap-4 flex-wrap">
        <div>
          <p class="font-medium">{gettext("Status")}</p>
          <p class="text-sm text-base-content/60">{status_message(@current_scope.venue)}</p>
        </div>
        <span class={["badge", status_badge_class(@current_scope.venue)]}>
          {status_badge_label(@current_scope.venue)}
        </span>
      </div>

      <form
        id="payment-settings-form"
        phx-submit="save"
        class="rounded-box bg-base-100 shadow-sm p-5 space-y-3"
      >
        <.input
          field={@form[:waafipay_merchant_uid]}
          type="password"
          label={gettext("Merchant UID")}
        />
        <.input
          field={@form[:waafipay_api_user_id]}
          type="password"
          label={gettext("API User ID")}
        />
        <.input field={@form[:waafipay_api_key]} type="password" label={gettext("API Key")} />
        <.input
          field={@form[:waafipay_store_id]}
          type="password"
          label={gettext("Store ID (optional — HPP only)")}
        />
        <.input
          field={@form[:waafipay_hpp_key]}
          type="password"
          label={gettext("HPP Key (optional — HPP only)")}
        />

        <div class="flex gap-2 pt-2">
          <button type="submit" class="btn btn-primary btn-sm">
            {gettext("Save credentials")}
          </button>
          <button
            :if={Venue.waafipay_credentials?(@current_scope.venue)}
            type="button"
            phx-click="verify"
            class="btn btn-outline btn-sm"
          >
            {gettext("Verify")}
          </button>
        </div>
      </form>
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
     |> assign(:form, to_form(Venue.waafipay_credentials_changeset(scope.venue, %{})))}
  end

  @impl true
  def handle_event("save", %{"venue" => params}, socket) do
    scope = socket.assigns.current_scope

    case Tenants.update_waafipay_credentials(scope, scope.venue, params) do
      {:ok, venue} ->
        {:noreply,
         socket
         |> put_venue(venue)
         |> assign(:form, to_form(Venue.waafipay_credentials_changeset(venue, %{})))
         |> put_flash(:info, gettext("Credentials saved — verify them before going live."))}

      {:error, changeset} ->
        {:noreply, assign(socket, :form, to_form(changeset))}
    end
  end

  def handle_event("verify", _params, socket) do
    scope = socket.assigns.current_scope

    case Payments.verify_credentials(scope, scope.venue) do
      {:ok, venue} ->
        {:noreply,
         socket
         |> put_venue(venue)
         |> put_flash(:info, gettext("Verified — this venue can now accept payments."))}

      {:error, _reason} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           gettext("Verification failed — double-check the credentials and try again.")
         )}
    end
  end

  defp put_venue(socket, venue) do
    assign(socket, :current_scope, %{socket.assigns.current_scope | venue: venue})
  end

  defp status_message(%Venue{charges_enabled: true}),
    do: gettext("Live — this venue can accept payments.")

  defp status_message(%Venue{} = venue) do
    if Venue.waafipay_credentials?(venue) do
      gettext("Credentials saved but not verified yet.")
    else
      gettext("No credentials on file yet.")
    end
  end

  defp status_badge_class(%Venue{charges_enabled: true}), do: "badge-success"
  defp status_badge_class(_venue), do: "badge-warning"

  defp status_badge_label(%Venue{charges_enabled: true}), do: gettext("Live")
  defp status_badge_label(_venue), do: gettext("Not live")
end
