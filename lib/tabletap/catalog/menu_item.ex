defmodule Tabletap.Catalog.MenuItem do
  @moduledoc """
  A sellable menu item (architecture.md Data Model). Two independent
  on/off switches, not one: `active` is the manager's long-term "is this
  on the menu at all" decision (independent of archiving — e.g. a
  seasonal item taken down without losing its config/photo/history);
  `available_today` is the daily-reset toggle tied to the venue's
  business day. Both must be true (and the item non-archived) for it to
  appear on `Catalog.list_public_menu/1`.

  `org_id`/`venue_id`/`category_id` are set programmatically by
  `Tabletap.Catalog`, never cast from user attrs (code-standards.md);
  moving an item between categories goes through
  `Catalog.move_item_to_category/3`, not a general update.

  `ingredients` is a free-text customer-facing list ("beef patty, brioche
  bun, cheddar") — descriptive only, not linked to stock. The structured
  ingredient/recipe/stock-deduction system (`ingredients` + `recipe_lines`
  tables, BOM, stock effects) is a separate concern landing in Feature 12.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @dietary_tags ~w(vegan vegetarian halal gluten_free dairy_free)
  @allergen_tags ~w(nuts dairy gluten shellfish eggs soy)

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "menu_items" do
    belongs_to :org, Tabletap.Tenants.Org
    belongs_to :venue, Tabletap.Tenants.Venue
    belongs_to :category, Tabletap.Catalog.Category

    field :name, :string
    field :description, :string
    field :ingredients, :string
    field :photo_url, :string
    field :price, Money.Ecto.Composite.Type
    field :prep_minutes, :integer
    field :active, :boolean, default: true
    field :available_today, :boolean, default: true
    field :dietary_tags, {:array, :string}, default: []
    field :allergen_tags, {:array, :string}, default: []
    field :position, :integer, default: 0
    field :archived_at, :utc_datetime

    has_many :daily_limits, Tabletap.Catalog.DailyItemLimit, foreign_key: :item_id

    timestamps(type: :utc_datetime)
  end

  def dietary_tag_options, do: @dietary_tags
  def allergen_tag_options, do: @allergen_tags

  def creation_changeset(item, attrs), do: validate(item, attrs)
  def update_changeset(item, attrs), do: validate(item, attrs)

  defp validate(item, attrs) do
    item
    |> cast(attrs, [
      :name,
      :description,
      :ingredients,
      :photo_url,
      :price,
      :prep_minutes,
      :active,
      :dietary_tags,
      :allergen_tags
    ])
    |> validate_required([:name, :price])
    |> validate_length(:name, min: 1, max: 120)
    |> validate_number(:prep_minutes, greater_than_or_equal_to: 0)
    |> validate_price()
    # A leading hidden "" input is how the tag checkboxes submit an empty
    # list when every box is unchecked (unchecked checkboxes send nothing
    # at all) — strip it before validating against the real tag options.
    |> update_change(:dietary_tags, &Enum.reject(&1, fn tag -> tag == "" end))
    |> update_change(:allergen_tags, &Enum.reject(&1, fn tag -> tag == "" end))
    |> validate_subset(:dietary_tags, @dietary_tags)
    |> validate_subset(:allergen_tags, @allergen_tags)
  end

  defp validate_price(changeset) do
    case get_field(changeset, :price) do
      %Money{} = price ->
        if Money.compare!(price, Money.new!(price.currency, 0)) == :gt do
          changeset
        else
          add_error(changeset, :price, "must be greater than zero")
        end

      _ ->
        changeset
    end
  end

  def availability_changeset(item, available_today) when is_boolean(available_today) do
    change(item, available_today: available_today)
  end

  @doc "Hides the item from menus/pickers; every report, snapshot, and FK stays intact."
  def archive_changeset(item), do: change(item, archived_at: DateTime.utc_now(:second))

  def position_changeset(item, position), do: change(item, position: position)

  @doc """
  `Catalog.move_item_to_category/3` already checks both the item's and the
  new category's `venue_id` before calling this — the constraint below is
  defense in depth, so a bypass of that check becomes a changeset error
  instead of a raised `Ecto.ConstraintError` from the composite FK.
  """
  def category_changeset(item, category_id, position) do
    item
    |> change(category_id: category_id, position: position)
    |> foreign_key_constraint(:category_id)
  end
end
