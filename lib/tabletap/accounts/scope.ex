defmodule Tabletap.Accounts.Scope do
  @moduledoc """
  The unit of authorization for every context function (architecture.md
  Multi-Tenancy; code-standards.md: "context functions take %Scope{} as
  the first argument"). Every tenant-owned query trusts `scope.org.id` /
  `scope.venue.id` — the Repo's `prepare_query` raise is the backstop,
  never the primary filter.

  `org`, `venue`, `membership`, and `role` are resolved by
  `Tabletap.Tenants.build_scope/2`, called once per request/mount from
  `TabletapWeb.UserAuth` — a logged-in user with no memberships (e.g. a
  future customer account, Feature 16) gets all four as `nil`, which is
  correct deny-by-default, not a bug. Customer/public QR routes build a
  scope directly from the resolved venue instead:
  `%Scope{org: org, venue: venue, role: :guest}` (architecture.md Customer
  Identity & QR Flow — lands with Feature 07).
  """

  alias Tabletap.Accounts.User

  defstruct user: nil, org: nil, venue: nil, membership: nil, role: nil

  @doc """
  Creates a scope for the given user.

  Returns nil if no user is given.
  """
  def for_user(%User{} = user) do
    %__MODULE__{user: user}
  end

  def for_user(nil), do: nil
end
