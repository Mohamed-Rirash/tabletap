defmodule TabletapWeb.UserLive.Confirmation do
  @moduledoc """
  The magic-link landing page — every role lands here (staff and
  customers alike): resolves the emailed token, then either confirms a
  brand-new account or logs an existing one in via the trigger-action
  form below (the actual session write happens in
  `UserSessionController`, a native POST, not this LiveView process).

  A `guest_token` query param (build-plan.md Feature 16's "Save your
  history" flow, appended only by `Public.OrderTrackerLive`'s own
  signup prompt) triggers `Ordering.link_guest_orders_to_customer/2` the
  moment the token resolves — reaching this page with a *valid,
  unexpired* magic-link token already proves the visitor owns this
  email, so the link doesn't wait for the "Confirm" button tap.
  """
  use TabletapWeb, :live_view

  alias Tabletap.{Accounts, Ordering}

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="mx-auto max-w-sm">
        <div class="text-center">
          <.header>Welcome {@user.email}</.header>
        </div>

        <.form
          :if={!@user.confirmed_at}
          for={@form}
          id="confirmation_form"
          phx-mounted={JS.focus_first()}
          phx-submit="submit"
          action={~p"/users/log-in?_action=confirmed"}
          phx-trigger-action={@trigger_submit}
        >
          <input type="hidden" name={@form[:token].name} value={@form[:token].value} />
          <.button
            name={@form[:remember_me].name}
            value="true"
            phx-disable-with="Confirming..."
            class="btn btn-primary w-full"
          >
            Confirm and stay logged in
          </.button>
          <.button phx-disable-with="Confirming..." class="btn btn-primary btn-soft w-full mt-2">
            Confirm and log in only this time
          </.button>
        </.form>

        <.form
          :if={@user.confirmed_at}
          for={@form}
          id="login_form"
          phx-submit="submit"
          phx-mounted={JS.focus_first()}
          action={~p"/users/log-in"}
          phx-trigger-action={@trigger_submit}
        >
          <input type="hidden" name={@form[:token].name} value={@form[:token].value} />
          <%= if @current_scope do %>
            <.button phx-disable-with="Logging in..." class="btn btn-primary w-full">
              Log in
            </.button>
          <% else %>
            <.button
              name={@form[:remember_me].name}
              value="true"
              phx-disable-with="Logging in..."
              class="btn btn-primary w-full"
            >
              Keep me logged in on this device
            </.button>
            <.button phx-disable-with="Logging in..." class="btn btn-primary btn-soft w-full mt-2">
              Log me in only this time
            </.button>
          <% end %>
        </.form>

        <p :if={!@user.confirmed_at} class="alert alert-outline mt-8">
          Tip: If you prefer passwords, you can enable them in the user settings.
        </p>
      </div>
    </Layouts.app>
    """
  end

  @impl true
  def mount(%{"token" => token} = params, _session, socket) do
    if user = Accounts.get_user_by_magic_link_token(token) do
      if guest_token = params["guest_token"] do
        Ordering.link_guest_orders_to_customer(user, guest_token)
      end

      form = to_form(%{"token" => token}, as: "user")

      {:ok, assign(socket, user: user, form: form, trigger_submit: false),
       temporary_assigns: [form: nil]}
    else
      {:ok,
       socket
       |> put_flash(:error, "Magic link is invalid or it has expired.")
       |> push_navigate(to: ~p"/users/log-in")}
    end
  end

  @impl true
  def handle_event("submit", %{"user" => params}, socket) do
    {:noreply, assign(socket, form: to_form(params, as: "user"), trigger_submit: true)}
  end
end
