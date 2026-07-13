defmodule Tabletap.Encrypted.Binary do
  @moduledoc """
  Shared `Cloak.Ecto.Binary` type for any field that needs encryption at
  rest via `Tabletap.Vault` (library-docs.md "Ecto — Tenant-Enforcing
  Repo" doesn't cover this, but the pattern mirrors it: one boring,
  reusable type rather than a one-off per schema). First caller is
  `Tenants.Venue`'s WaafiPay merchant credentials (design-qa.md Q57/Q58
  — encrypted, never logged).
  """
  use Cloak.Ecto.Binary, vault: Tabletap.Vault
end
