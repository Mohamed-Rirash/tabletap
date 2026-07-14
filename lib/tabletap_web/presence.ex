defmodule TabletapWeb.Presence do
  @moduledoc """
  Tracks connected, on-shift waiters on `venue:{id}:staff`
  (architecture.md "Real-time Topology"; build-plan.md Feature 10). The
  waiter-assignment algorithm only considers `alive?/2` candidates.

  **Flap grace (design-qa.md Q55):** restaurant WiFi bounces phones
  between WiFi and cellular; a strict "gone the instant Presence says
  leave" rule would drop a waiter, escalate their order, then re-add
  them 20 seconds later. `handle_metas/4` is `Phoenix.Presence`'s own
  extension point for exactly this — a `leave` doesn't immediately clear
  the local liveness cache; it schedules a confirmation ~30s out via
  `:timer.apply_after/4` (deliberately not `Process.send_after(self(),
  ...)` — `self()` inside `handle_metas/4` is the library's own Tracker
  process, whose `handle_info/2` is Phoenix.Presence's, not ours; a
  message sent there for anything but the library's own async-merge
  protocol would crash the tracker). A `join` in the meantime (the same
  membership reconnecting) cancels the pending confirmation. Per-venue
  flap telemetry counts every cancelled leave, so a venue's bad WiFi is
  visible to us before they complain.
  """
  use Phoenix.Presence, otp_app: :tabletap, pubsub_server: Tabletap.PubSub

  @grace_ms 30_000
  @table :tabletap_presence_liveness

  def staff_topic(venue_id), do: "venue:#{venue_id}:staff"

  @doc "Whether `membership_id` is currently a live assignment candidate — tracked now, or within the flap-grace window of a leave."
  def alive?(venue_id, membership_id) do
    case :ets.lookup(@table, {venue_id, membership_id}) do
      [{_key, _}] -> true
      [] -> false
    end
  end

  @doc "Every membership_id currently a live assignment candidate at `venue_id`."
  def alive_membership_ids(venue_id) do
    :ets.match(@table, {{venue_id, :"$1"}, :_}) |> List.flatten()
  end

  @impl true
  def init(_opts) do
    unless :ets.whereis(@table) != :undefined do
      :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    end

    {:ok, %{}}
  end

  @impl true
  def handle_metas("venue:" <> rest, %{joins: joins, leaves: leaves}, _presences, state) do
    case String.split(rest, ":") do
      [venue_id, "staff"] ->
        Enum.each(joins, fn {membership_id, _meta} -> handle_join(venue_id, membership_id) end)
        Enum.each(leaves, fn {membership_id, _meta} -> handle_leave(venue_id, membership_id) end)

      _other ->
        :ok
    end

    {:ok, state}
  end

  def handle_metas(_topic, _diff, _presences, state), do: {:ok, state}

  @doc false
  def confirm_leave(venue_id, membership_id) do
    key = {venue_id, membership_id}

    case :ets.lookup(@table, key) do
      [{^key, {:grace, _tref}}] ->
        :ets.delete(@table, key)

        Phoenix.PubSub.broadcast(
          Tabletap.PubSub,
          staff_topic(venue_id),
          {:waiter_gone, membership_id}
        )

      _still_online_or_already_gone ->
        :ok
    end
  end

  defp handle_join(venue_id, membership_id) do
    key = {venue_id, membership_id}

    case :ets.lookup(@table, key) do
      [{^key, {:grace, tref}}] ->
        :timer.cancel(tref)
        :ets.insert(@table, {key, :online})

        :telemetry.execute([:tabletap, :staffing, :presence_flap], %{}, %{
          venue_id: venue_id,
          membership_id: membership_id
        })

      _ ->
        :ets.insert(@table, {key, :online})
    end
  end

  defp handle_leave(venue_id, membership_id) do
    key = {venue_id, membership_id}

    {:ok, tref} =
      :timer.apply_after(@grace_ms, __MODULE__, :confirm_leave, [venue_id, membership_id])

    :ets.insert(@table, {key, {:grace, tref}})
  end
end
