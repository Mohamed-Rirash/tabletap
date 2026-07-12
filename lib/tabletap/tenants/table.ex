defmodule Tabletap.Tenants.Table do
  @moduledoc """
  A physical table in a venue (architecture.md "Floor & Catalog"). Its
  `qr_token` is an opaque random string — the printed QR encodes
  `/t/:qr_token`, never the table/venue ids, so a rotated token
  instantly kills a stolen or photographed code (design-qa.md Q6/Q7).

  Archived, never deleted, once it's ever had an order — design-qa.md
  Q41. `org_id`/`venue_id`/`qr_token` are set programmatically by
  `Tabletap.Tenants`, never cast from user attrs (code-standards.md).
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "tables" do
    belongs_to :org, Tabletap.Tenants.Org
    belongs_to :venue, Tabletap.Tenants.Venue

    field :number, :string
    field :label, :string
    field :qr_token, :string
    field :active, :boolean, default: true
    field :archived_at, :utc_datetime

    timestamps(type: :utc_datetime)
  end

  def creation_changeset(table, attrs), do: validate(table, attrs)
  def update_changeset(table, attrs), do: validate(table, attrs)

  defp validate(table, attrs) do
    table
    |> cast(attrs, [:number, :label, :active])
    |> update_change(:number, &maybe_trim/1)
    |> update_change(:label, &maybe_trim/1)
    |> validate_required([:number])
    |> validate_length(:number, min: 1, max: 20)
    |> validate_length(:label, max: 60)
    # Error surfaces on :number (the form field) rather than :venue_id.
    |> unique_constraint(:number, name: :tables_venue_number_index)
  end

  defp maybe_trim(nil), do: nil
  defp maybe_trim(value), do: String.trim(value)

  @doc "A fresh opaque token — url-safe, unguessable (~22 chars)."
  def generate_qr_token, do: :crypto.strong_rand_bytes(16) |> Base.url_encode64(padding: false)

  @doc "Assigns a brand-new token, invalidating the old printed QR (design-qa.md Q7)."
  def rotate_changeset(table), do: change(table, qr_token: generate_qr_token())

  @doc "Hides the table from pickers/floor; every order and FK stays intact (design-qa.md Q41)."
  def archive_changeset(table), do: change(table, archived_at: DateTime.utc_now(:second))
end
