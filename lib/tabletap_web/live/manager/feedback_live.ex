defmodule TabletapWeb.Manager.FeedbackLive do
  @moduledoc """
  The manager feedback screen (build-plan.md Feature 17): every rating
  this venue has ever received, newest first, live — a new rating from
  a customer's phone appears here the instant `Feedback.rate_item/5`
  commits, no refresh (the feature's own verify step). Deliberately
  simple: trend lines, per-item/per-waiter breakdowns, and the
  low-rating alert all belong to owner-dashboard.md's much richer
  "Screen 4 — Feedback" — that's Feature 18 (Analytics Dashboard &
  Rollups) territory, not this one.
  """
  use TabletapWeb, :live_view

  alias Tabletap.{Feedback, Tenants}

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.manager
      flash={@flash}
      current_scope={@current_scope}
      active_nav={:feedback}
      venues={@venues}
    >
      <h1 class="text-2xl font-bold mb-2">{gettext("Feedback")}</h1>
      <p class="text-sm text-base-content/60 mb-6 max-w-prose">
        {gettext("Every rating your customers have left, newest first.")}
      </p>

      <div :if={@ratings == []} class="rounded-box bg-base-100 border border-base-300 p-6 text-center">
        <.icon name="hero-chat-bubble-left-right" class="size-8 mx-auto opacity-40" />
        <p class="mt-2 font-medium">{gettext("No ratings yet.")}</p>
        <p class="text-sm text-base-content/60">
          {gettext("They'll show up here the moment a customer rates a served order.")}
        </p>
      </div>

      <div
        :if={@ratings != []}
        class="rounded-box bg-base-100 border border-base-300 divide-y divide-base-300"
      >
        <div :for={rating <- @ratings} id={"rating-#{rating.id}"} class="p-4">
          <div class="flex items-start justify-between gap-3">
            <div class="min-w-0">
              <p class="font-medium">{rating.order_item.menu_item.name}</p>
              <p class="text-xs text-base-content/50">
                {gettext("Order #%{number} — %{date}",
                  number: rating.order_item.order.number,
                  date: Calendar.strftime(rating.inserted_at, "%b %-d, %Y %H:%M")
                )}
              </p>
            </div>
            <div class="flex items-center gap-0.5 shrink-0">
              <.icon
                :for={n <- 1..5}
                name={if n <= rating.stars, do: "hero-star-solid", else: "hero-star"}
                class={["size-4", n <= rating.stars && "text-warning"]}
              />
            </div>
          </div>
          <p :if={rating.comment} class="text-sm text-base-content/70 mt-2 italic">
            "{rating.comment}"
          </p>
        </div>
      </div>
    </Layouts.manager>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    scope = socket.assigns.current_scope

    if connected?(socket) do
      Phoenix.PubSub.subscribe(Tabletap.PubSub, "venue:#{scope.venue.id}:ratings")
    end

    {:ok,
     socket
     |> assign(:hide_utility_bar, true)
     |> assign(:venues, Tenants.list_venues(scope))
     |> assign(:ratings, Feedback.list_venue_feedback(scope))}
  end

  @impl true
  def handle_info({:rating_submitted, _menu_item_id}, socket) do
    {:noreply,
     assign(socket, :ratings, Feedback.list_venue_feedback(socket.assigns.current_scope))}
  end
end
