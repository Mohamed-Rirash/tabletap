defmodule TabletapWeb.UserLive.Registration do
  @moduledoc """
  The org-signup flow — the only thing `/users/register` is ever used for
  in this app (build-plan.md Feature 03 "Org signup flow: create org →
  first venue → owner membership"; the marketing page's "Start free — 14
  days, no card" button lands here). Owner accounts require a password up
  front (design-qa.md Q47), so unlike the generic magic-link registration
  this generator started from, submitting here logs the owner straight in
  — no confirmation email round-trip.
  """
  use TabletapWeb, :live_view

  alias Tabletap.Tenants

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="mx-auto max-w-sm">
        <div class="text-center">
          <.header>
            {gettext("Start your free trial")}
            <:subtitle>
              {gettext("14 days, full features, no card required.")}
              <.link navigate={~p"/users/log-in"} class="font-semibold text-brand hover:underline">
                {gettext("Log in")}
              </.link>
              {gettext("if you already have an account.")}
            </:subtitle>
          </.header>
        </div>

        <.form
          for={@form}
          id="registration_form"
          action={~p"/users/log-in"}
          phx-trigger-action={@trigger_submit}
          phx-submit="save"
          phx-change="validate"
        >
          <.input
            field={@form[:business_name]}
            type="text"
            label={gettext("Business name")}
            placeholder={gettext("Cadaani Coffee")}
            required
            phx-mounted={JS.focus()}
          />
          <.input
            field={@form[:city]}
            type="select"
            label={gettext("City")}
            options={Enum.map(Tenants.city_options(), fn {name, _currency, _tz} -> name end)}
            required
          />
          <.input
            field={@form[:email]}
            type="email"
            label={gettext("Your email")}
            autocomplete="username"
            spellcheck="false"
            required
          />
          <.input
            field={@form[:password]}
            type="password"
            label={gettext("Password")}
            autocomplete="new-password"
            required
          />
          <.input
            field={@form[:password_confirmation]}
            type="password"
            label={gettext("Confirm password")}
            autocomplete="new-password"
            required
          />
          <input type="hidden" name="user[remember_me]" value="true" />

          <.button phx-disable-with={gettext("Creating your venue...")} class="btn btn-primary w-full">
            {gettext("Start free — 14 days, no card")}
          </.button>
        </.form>
      </div>
    </Layouts.app>
    """
  end

  @impl true
  def mount(_params, _session, %{assigns: %{current_scope: %{user: user}}} = socket)
      when not is_nil(user) do
    {:ok, redirect(socket, to: TabletapWeb.UserAuth.signed_in_path(socket))}
  end

  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:trigger_submit, false)
     |> assign_form(signup_changeset(%{}))}
  end

  @impl true
  def handle_event("validate", %{"user" => params}, socket) do
    changeset = params |> signup_changeset() |> Map.put(:action, :validate)
    {:noreply, assign_form(socket, changeset)}
  end

  def handle_event("save", %{"user" => params}, socket) do
    changeset = signup_changeset(params)

    if changeset.valid? do
      create_org(socket, params, changeset)
    else
      {:noreply, assign_form(socket, Map.put(changeset, :action, :validate))}
    end
  end

  defp create_org(socket, params, changeset) do
    case Tenants.create_org_with_owner(params) do
      {:ok, %{user: _user}} ->
        # Re-render the form from the just-submitted (valid) changeset
        # before triggering the native POST — without this, @form still
        # holds mount/3's blank initial changeset whenever "save" fires
        # without a prior "validate" (e.g. a single programmatic submit),
        # so the auto-login POST would carry empty email/password.
        {:noreply, socket |> assign_form(changeset) |> assign(:trigger_submit, true)}

      # The realistic failure here is the email already being taken — the
      # User changeset shares :email/:password field names with this form,
      # so it renders inline. Org/Venue changesets can't meaningfully fail
      # once the schemaless pre-check above has passed (business_name is
      # already required there; currency/timezone are resolved server-side,
      # never user input) — that branch is a defensive fallback, not an
      # expected path.
      {:error, %Ecto.Changeset{data: %Tabletap.Accounts.User{}} = user_changeset} ->
        {:noreply, assign_form(socket, Map.put(user_changeset, :action, :validate))}

      {:error, %Ecto.Changeset{}} ->
        {:noreply,
         socket
         |> put_flash(
           :error,
           gettext("Something went wrong setting up your venue. Please try again.")
         )
         |> assign_form(changeset)}
    end
  end

  # Schemaless changeset for live validation — the real, authoritative
  # validation happens per-schema inside Tenants.create_org_with_owner/1;
  # this exists only to give the form inline field errors before that
  # multi-table transaction ever runs.
  @signup_types %{
    business_name: :string,
    city: :string,
    email: :string,
    password: :string,
    password_confirmation: :string
  }

  defp signup_changeset(attrs) do
    {%{}, @signup_types}
    |> Ecto.Changeset.cast(attrs, Map.keys(@signup_types))
    |> Ecto.Changeset.validate_required([
      :business_name,
      :city,
      :email,
      :password,
      :password_confirmation
    ])
    |> Ecto.Changeset.validate_length(:business_name, min: 2, max: 120)
    |> Ecto.Changeset.validate_format(:email, ~r/^[^@,;\s]+@[^@,;\s]+$/,
      message: "must have the @ sign and no spaces"
    )
    |> Ecto.Changeset.validate_length(:password, min: 12, max: 72)
    |> Ecto.Changeset.validate_confirmation(:password, message: "does not match password")
    |> Ecto.Changeset.validate_inclusion(
      :city,
      Enum.map(Tenants.city_options(), fn {name, _currency, _tz} -> name end)
    )
  end

  defp assign_form(socket, %Ecto.Changeset{} = changeset) do
    assign(socket, :form, to_form(changeset, as: "user"))
  end
end
