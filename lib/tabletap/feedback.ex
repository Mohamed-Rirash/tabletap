defmodule Tabletap.Feedback do
  @moduledoc """
  Item ratings (architecture.md "feedback/"; build-plan.md Feature 17).
  Aggregates are always live-computed from `item_ratings`, never cached
  on `menu_items` — per-venue rating volume is small enough that a
  grouped query on read costs nothing, and a cached column is one more
  place to drift out of sync.
  """

  import Ecto.Query, warn: false

  alias Tabletap.Accounts.Scope
  alias Tabletap.Feedback.ItemRating
  alias Tabletap.Ordering.{Order, OrderItem}
  alias Tabletap.Repo

  # A rating only makes sense once the food actually reached the
  # customer — `:closed` is `:served`'s own natural follow-up (the only
  # path to `:closed` is through `:served`), but `:refunded` is
  # deliberately excluded: it's reachable from several pre-serve
  # statuses too (a manager can refund a `:placed` order that was never
  # made), so `order.status == :refunded` alone can't tell "was this
  # ever served" from "was it refunded before the kitchen touched it."
  @rateable_statuses [:served, :closed]

  @doc """
  Rates one order line. `{:error, :not_yet_served}` before the order
  has reached the customer; `{:error, :already_rated}` on a second
  attempt for the same line — "one rating per served order item" is
  enforced at the DB layer (`ItemRating`'s own unique index on
  `order_item_id`), so a race between two taps can never double-insert;
  this just translates that constraint into a named atom instead of a
  raw changeset error. Broadcasts on the venue's ratings topic so the
  public menu's live average and the manager feedback screen both pick
  it up without a refresh.
  """
  def rate_item(
        %Scope{org: org, venue: venue},
        %Order{} = order,
        %OrderItem{} = order_item,
        stars,
        opts \\ []
      ) do
    if order.status in @rateable_statuses do
      attrs = %{
        org_id: org.id,
        venue_id: venue.id,
        order_item_id: order_item.id,
        menu_item_id: order_item.menu_item_id,
        customer_user_id: Keyword.get(opts, :customer_user_id),
        stars: stars,
        comment: Keyword.get(opts, :comment)
      }

      attrs
      |> ItemRating.new_changeset()
      |> Repo.insert()
      |> case do
        {:ok, rating} ->
          broadcast(venue, order_item.menu_item_id)
          {:ok, rating}

        {:error, %Ecto.Changeset{} = changeset} ->
          translate_insert_error(changeset)
      end
    else
      {:error, :not_yet_served}
    end
  end

  defp translate_insert_error(changeset) do
    if Keyword.has_key?(changeset.errors, :order_item_id),
      do: {:error, :already_rated},
      else: {:error, changeset}
  end

  defp broadcast(venue, menu_item_id) do
    Phoenix.PubSub.broadcast(
      Tabletap.PubSub,
      "venue:#{venue.id}:ratings",
      {:rating_submitted, menu_item_id}
    )
  end

  @doc "Which of these order items already have a rating — the tracker's own per-item hide-after-rating check, one query for the whole order."
  def rated_order_item_ids(%Scope{}, order_item_ids) when is_list(order_item_ids) do
    Repo.all(
      from(r in ItemRating, where: r.order_item_id in ^order_item_ids, select: r.order_item_id)
    )
    |> MapSet.new()
  end

  @doc """
  Avg stars + count per menu item, for every id in `menu_item_ids` — one
  query for a whole menu grid, never N+1. An item with zero ratings
  simply has no entry in the returned map (never a `%{avg: nil}` the
  caller has to special-case).
  """
  def ratings_summary_for_items(%Scope{venue: venue}, menu_item_ids)
      when is_list(menu_item_ids) do
    Repo.all(
      from(r in ItemRating,
        where: r.venue_id == ^venue.id and r.menu_item_id in ^menu_item_ids,
        group_by: r.menu_item_id,
        select: {r.menu_item_id, %{avg: avg(r.stars), count: count(r.id)}}
      )
    )
    |> Map.new()
  end

  @doc "Every rating for this venue, newest first — the manager feedback screen. Order/menu-item context preloaded for display."
  def list_venue_feedback(%Scope{venue: venue}) do
    Repo.all(
      from(r in ItemRating,
        where: r.venue_id == ^venue.id,
        # `inserted_at` is second-precision (matches this codebase's
        # `:utc_datetime` convention elsewhere) — two ratings landing in
        # the same second are a real possibility, not just a test race,
        # so `:id` breaks the tie deterministically.
        order_by: [desc: r.inserted_at, desc: r.id],
        preload: [order_item: [:menu_item, :order]]
      )
    )
  end
end
