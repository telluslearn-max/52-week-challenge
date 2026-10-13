defmodule SavingsChallenge.Challenge do
  use Ecto.Schema
  import Ecto.Changeset

  alias SavingsChallenge.{Clock, Contribution}

  @max_amount 10_000_000

  @categories [
    {"trip", "Trip"},
    {"equipment", "Equipment"},
    {"emergency", "Emergency fund"},
    {"home", "Home & household"},
    {"education", "Education"},
    {"gift", "Gift or event"},
    {"general", "General"}
  ]

  def categories, do: @categories

  def category_label(value) do
    Enum.find_value(@categories, "General", fn {v, label} -> v == value && label end)
  end

  schema "challenges" do
    field :name, :string, default: "My savings goal"
    field :category, :string, default: "general"
    field :mode, :string, default: "increasing"
    field :start_amount, :integer, default: 50
    field :increment, :integer, default: 50
    field :target_amount, :integer
    field :start_date, :date

    has_many :contributions, Contribution

    timestamps(type: :utc_datetime)
  end

  def changeset(challenge, attrs) do
    challenge
    |> cast(attrs, [:name, :category, :mode, :start_amount, :increment, :target_amount, :start_date])
    |> update_change(:name, &String.trim/1)
    |> validate_required([:name, :category, :mode, :start_amount, :start_date])
    |> validate_length(:name, max: 60)
    |> validate_inclusion(:mode, ["increasing", "fixed"])
    |> validate_inclusion(:category, Enum.map(@categories, &elem(&1, 0)))
    |> validate_number(:start_amount, greater_than: 0, less_than_or_equal_to: @max_amount)
    |> validate_number(:increment, greater_than_or_equal_to: 0, less_than_or_equal_to: @max_amount)
    |> validate_number(:target_amount, greater_than: 0, less_than_or_equal_to: @max_amount * 52)
    |> normalise_fixed()
    |> check_constraint(:start_amount, name: :start_amount_positive)
  end

  # A fixed plan has no increment; a blank increment on an increasing plan means 0.
  defp normalise_fixed(changeset) do
    cond do
      get_field(changeset, :mode) == "fixed" -> put_change(changeset, :increment, 0)
      is_nil(get_field(changeset, :increment)) -> put_change(changeset, :increment, 0)
      true -> changeset
    end
  end

  @doc "A challenge struct with sensible defaults, starting today."
  def new_default, do: %__MODULE__{start_date: Clock.today()}
end
