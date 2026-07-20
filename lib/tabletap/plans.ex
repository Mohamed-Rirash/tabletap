defmodule Tabletap.Plans do
  @moduledoc """
  The compiled plan catalog (build-plan.md Feature 19; pricing.md is the
  source of the actual numbers, `config/plans.exs` their compiled form).
  Every plan/feature/price/cap decision anywhere in the app funnels
  through this module — nothing else hardcodes a fee rate or a venue
  cap (code-standards.md: "changing a fee is a deploy, deliberately").

  A trialing org (`org.subscription_status == :trialing`) gets every
  tier's gated features unlocked regardless of `org.plan` (pricing.md
  "Trial" — "no card required" describes the trial's entry cost, not a
  fee waiver, so `fee_rate/1` still charges the Essentials rate during
  trial even though `feature_enabled?/2` unlocks everything).
  """

  alias Tabletap.Tenants.Org

  @plans Application.compile_env!(:tabletap, :plans)
  @tiers [:essentials, :growth, :pro]

  @doc "Plan atoms in ascending tier order — cheapest/most-restricted first."
  def tiers, do: @tiers

  @doc "The full config keyword list for one plan. Raises on an unknown plan atom — that's a bug, not a user error."
  def get(plan) when plan in @tiers, do: Keyword.fetch!(@plans, plan)

  @doc "Display name, e.g. \"Growth\"."
  def name(plan), do: get(plan) |> Keyword.fetch!(:name)

  @doc "Max active venues this plan allows for one org."
  def venue_cap(plan), do: get(plan) |> Keyword.fetch!(:venue_cap)

  @doc """
  Monthly subscription price as `Money.t()`. `venue_count` matters only
  for Pro (`per_venue?: true` in config/plans.exs) — every other plan
  ignores it, since Essentials/Growth cap at 1 venue anyway.
  """
  def monthly_price(plan, venue_count \\ 1) do
    config = get(plan)
    unit = Money.new!(:USD, Keyword.fetch!(config, :monthly_price))

    if Keyword.fetch!(config, :per_venue?) do
      Money.mult!(unit, venue_count)
    else
      unit
    end
  end

  @doc """
  Per-order platform fee rate, as a `Decimal.t()`. A trialing org accrues
  at the Essentials rate (pricing.md "Trial") regardless of which plan
  it'll eventually pick.
  """
  def fee_rate(%Org{subscription_status: :trialing}), do: fee_rate(:essentials)
  def fee_rate(%Org{plan: plan}), do: fee_rate(plan)

  def fee_rate(plan) when plan in @tiers,
    do: get(plan) |> Keyword.fetch!(:fee_rate) |> Decimal.new()

  @doc """
  Whether a gated feature (`:inventory`, `:report_center`,
  `:org_comparison`) is available to this org right now. Trialing orgs
  see every feature across every tier (pricing.md "Trial") so a
  prospective Growth/Pro customer can evaluate the depth before paying
  for it. A feature not listed in any plan's config (a typo, or the
  order-loop basics every tier already has) is never enabled by this
  function — callers shouldn't gate features that aren't actually
  tiered.
  """
  def feature_enabled?(%Org{subscription_status: :trialing}, _feature), do: true

  def feature_enabled?(%Org{plan: plan}, feature) do
    feature in (get(plan) |> Keyword.fetch!(:features))
  end

  @doc """
  The cheapest tier whose feature list includes `feature`, or `nil` if
  no plan gates it at all (gating an ungated feature would be a caller
  bug, not a real upgrade prompt). Backs the "billing screen names
  exactly what's blocking" pattern (pricing.md, design-qa.md Q48).
  """
  def min_tier_for(feature) do
    Enum.find(@tiers, fn tier -> feature in (get(tier) |> Keyword.fetch!(:features)) end)
  end

  @doc "Flash-ready copy for a feature-gated redirect: names the cheapest plan that unlocks it."
  def upgrade_message(feature) do
    case min_tier_for(feature) do
      nil -> "That feature isn't available on any plan."
      tier -> "That feature requires the #{name(tier)} plan or higher."
    end
  end
end
