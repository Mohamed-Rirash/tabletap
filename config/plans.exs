# Plan definitions — pricing.md is the single source of the actual
# numbers; this file is just their compiled form. code-standards.md:
# "changing a fee is a deploy, deliberately" — a repricing is a one-file
# diff here, never scattered literals across contexts (Tabletap.Plans
# reads this config; nothing else hardcodes a price, fee rate, or venue
# cap).
#
# `monthly_price` is USD-only at this phase (design-qa.md Q61 — Jigjiga's
# ETB pricing is deliberately unset until that phase's gates clear).
# `per_venue?: true` (Pro only) means `monthly_price` is charged once per
# active venue, not once per org.
import Config

config :tabletap, :plans,
  essentials: [
    name: "Essentials",
    monthly_price: "40.00",
    per_venue?: false,
    fee_rate: "0.025",
    venue_cap: 1,
    features: []
  ],
  growth: [
    name: "Growth",
    monthly_price: "75.00",
    per_venue?: false,
    fee_rate: "0.015",
    venue_cap: 1,
    features: [:inventory, :report_center]
  ],
  pro: [
    name: "Pro",
    monthly_price: "55.00",
    per_venue?: true,
    fee_rate: "0.010",
    venue_cap: 10,
    features: [:inventory, :report_center, :org_comparison]
  ]
