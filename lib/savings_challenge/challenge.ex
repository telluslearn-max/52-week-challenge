defmodule SavingsChallenge.Challenge do
  use Ecto.Schema
  import Ecto.Changeset

  alias SavingsChallenge.{Clock, Contribution, GoalItem}

  @max_amount 10_000_000

  # {group, [{value, label, icon}]}: drives the picker, the select and validation.
  @category_groups [
    {"Featured",
     [{"emergency", "Emergency", "🛟"}, {"business", "Business", "💼"}, {"charity", "Charity", "🤝"}, {"general", "Other", "🪙"}]},
    {"Home",
     [
       {"rent", "Rent", "🏢"},
       {"furniture", "Furniture", "🛋️"},
       {"kitchen", "Kitchenware", "🍳"},
       {"land", "Land", "🌳"},
       {"house", "House", "🏠"},
       {"bills", "Bills & utilities", "💡"},
       {"subscription", "Subscriptions", "📺"}
     ]},
    {"Shopping",
     [{"shoes", "Shoes", "👟"}, {"clothes", "Clothes", "👗"}, {"electronics", "Electronics", "📺"}, {"equipment", "Equipment & tools", "🛠️"}]},
    {"Personal", [{"insurance", "Insurance", "☂️"}, {"education", "Education", "🎓"}, {"debt", "Clear debt", "🧾"}]},
    {"Fun", [{"event", "Life event", "🎉"}, {"gift", "Gift", "🎁"}, {"trip", "Trip or vacation", "🏝️"}]}
  ]

  @categories for {_group, items} <- @category_groups, {value, label, icon} <- items, do: {value, label, icon}

  def category_groups, do: @category_groups
  def category_values, do: Enum.map(@categories, &elem(&1, 0))
  def valid_category?(value), do: value in category_values()

  def category_label(value), do: find_category(value) |> elem(1)
  def category_icon(value), do: find_category(value) |> elem(2)

  defp find_category(value), do: List.keyfind(@categories, value, 0) || {"general", "Other", "🪙"}

  # {value, title, description} for the plan cards in the form.
  @plans [
    {"weekly_increasing", "52 weeks, growing", "Start small and add a bit more every week"},
    {"weekly_fixed", "52 weeks, fixed", "The same amount every week"},
    {"daily", "100 days (Mia kwa Mia)", "The same amount every day for 100 days"},
    {"envelope", "12 weekly envelopes", "A surprise multiplier from 1 to 12 each week"},
    {"tranche", "52 tranches, no deadline", "Split a big goal into 52 equal parts and fill them whenever you have money"},
    {"deadline", "Goal and deadline", "Pick an amount and a date; we work out each deposit"},
    {"bill", "Bill or subscription", "Set a little aside each day or week so it is covered when due"}
  ]

  @recurrences [{"once", "Once"}, {"weekly", "Every week"}, {"monthly", "Every month"}, {"quarterly", "Every 3 months"}, {"yearly", "Every year"}]
  def recurrences, do: @recurrences

  @max_periods %{"day" => 366, "week" => 156, "month" => 60}

  # Shown as a "Challenges" row at the top of the picker: {plan, label, icon}.
  def challenge_tiles do
    [
      {"weekly_increasing", "52-week challenge", "🗓️"},
      {"daily", "100 days (Mia kwa Mia)", "💯"},
      {"envelope", "12 weekly envelopes", "✉️"},
      {"tranche", "52 tranches, no deadline", "🚗"},
      {"deadline", "Goal and deadline", "🎯"},
      {"bill", "Bill or subscription", "🧾"}
    ]
  end

  def plans, do: @plans
  def plan_values, do: Enum.map(@plans, &elem(&1, 0))
  def valid_plan?(value), do: value in plan_values()

  def plan_label("weekly_increasing"), do: "52-Week Challenge"
  def plan_label("weekly_fixed"), do: "52-Week Challenge"
  def plan_label("daily"), do: "100 Days Challenge"
  def plan_label("envelope"), do: "Envelope Challenge"
  def plan_label("bill"), do: "Bill"
  def plan_label("tranche"), do: "52 Tranches"
  def plan_label(_), do: "My savings goal"

  @doc "Which plan card a saved challenge corresponds to."
  def plan_of(%{kind: "daily"}), do: "daily"
  def plan_of(%{kind: "envelope"}), do: "envelope"
  def plan_of(%{kind: "deadline"}), do: "deadline"
  def plan_of(%{kind: "bill"}), do: "bill"
  def plan_of(%{kind: "tranche"}), do: "tranche"
  def plan_of(%{mode: "fixed"}), do: "weekly_fixed"
  def plan_of(_), do: "weekly_increasing"

  @doc "Fills the form-only fields so the edit form shows the current plan."
  def with_plan(c), do: %{c | plan: plan_of(c), frequency: c.unit}

  schema "challenges" do
    field :name, :string, default: "My savings goal"
    field :category, :string, default: "general"
    # kind: weekly (52-week) | daily (100 days) | envelope (12 weeks) | deadline (goal + date)
    field :kind, :string, default: "weekly"
    field :unit, :string, default: "week"
    field :periods, :integer, default: 52
    field :multipliers, {:array, :integer}, default: []
    field :mode, :string, default: "increasing"
    field :start_amount, :integer, default: 50
    field :increment, :integer, default: 50
    field :target_amount, :integer
    field :start_date, :date
    field :end_date, :date
    field :completed_at, :utc_datetime
    field :recurrence, :string, default: "once"
    field :cycle, :integer, default: 1
    field :kept_in, :string

    # Form-only: which plan card was chosen, and how often a deadline goal is saved to.
    field :plan, :string, virtual: true
    field :frequency, :string, virtual: true, default: "week"

    has_many :contributions, Contribution
    has_many :items, GoalItem

    timestamps(type: :utc_datetime)
  end

  def changeset(challenge, attrs) do
    challenge
    |> cast(attrs, [:name, :category, :mode, :start_amount, :increment, :target_amount, :start_date, :end_date, :plan, :frequency, :kept_in, :recurrence])
    |> update_change(:name, &String.trim/1)
    |> update_change(:kept_in, &String.trim/1)
    |> validate_length(:kept_in, max: 200)
    |> derive_plan()
    |> validate_required([:name, :category, :mode, :start_amount, :start_date])
    |> validate_length(:name, max: 60)
    |> validate_inclusion(:mode, ["increasing", "fixed"])
    |> validate_inclusion(:recurrence, Enum.map(@recurrences, &elem(&1, 0)))
    |> validate_inclusion(:category, category_values())
    |> validate_number(:start_amount, greater_than: 0, less_than_or_equal_to: @max_amount)
    |> validate_number(:increment, greater_than_or_equal_to: 0, less_than_or_equal_to: @max_amount)
    |> validate_number(:target_amount, greater_than: 0, less_than_or_equal_to: @max_amount * 52)
    |> normalise_fixed()
    |> check_constraint(:start_amount, name: :start_amount_positive)
  end

  # Turns the chosen plan card into the stored kind/unit/periods/mode. With no
  # plan given (older callers, tests) the challenge's current fields are used.
  defp derive_plan(changeset) do
    case get_field(changeset, :plan) do
      nil ->
        changeset

      "weekly_increasing" ->
        put_all(changeset, kind: "weekly", mode: "increasing", unit: "week", periods: 52)

      "weekly_fixed" ->
        put_all(changeset, kind: "weekly", mode: "fixed", unit: "week", periods: 52, increment: 0)

      "daily" ->
        put_all(changeset, kind: "daily", mode: "fixed", unit: "day", periods: 100, increment: 0, target_amount: nil)

      "envelope" ->
        changeset
        |> put_all(kind: "envelope", mode: "fixed", unit: "week", periods: 12, increment: 0, target_amount: nil)
        |> ensure_multipliers()

      "tranche" ->
        derive_tranche(changeset)

      "deadline" ->
        derive_deadline(changeset, "deadline")

      "bill" ->
        derive_deadline(changeset, "bill")

      _ ->
        add_error(changeset, :plan, "is invalid")
    end
  end

  defp put_all(changeset, changes), do: Enum.reduce(changes, changeset, fn {k, v}, cs -> put_change(cs, k, v) end)

  # Each of the 12 weeks gets a different multiplier 1..12, fixed when the goal is created.
  defp ensure_multipliers(changeset) do
    if Enum.sort(get_field(changeset, :multipliers) || []) == Enum.to_list(1..12) do
      changeset
    else
      put_change(changeset, :multipliers, Enum.shuffle(1..12))
    end
  end

  # 52 equal parts of the goal, filled in order whenever money comes in: no dates.
  defp derive_tranche(changeset) do
    changeset =
      changeset
      |> put_all(kind: "tranche", mode: "fixed", increment: 0, unit: "tranche", periods: 52, end_date: nil)
      |> validate_required([:target_amount], message: "is needed")

    case get_field(changeset, :target_amount) do
      target when is_integer(target) and target > 0 -> put_change(changeset, :start_amount, div(target + 51, 52))
      _ -> put_change(changeset, :start_amount, 1)
    end
  end

  # Goal + deadline + frequency => number of periods and the amount per period.
  defp derive_deadline(changeset, kind) do
    frequency = get_field(changeset, :frequency)
    target = get_field(changeset, :target_amount)
    start = get_field(changeset, :start_date)
    stop = get_field(changeset, :end_date)

    changeset = put_all(changeset, kind: kind, mode: "fixed", increment: 0)

    cond do
      frequency not in Map.keys(@max_periods) ->
        changeset |> add_error(:frequency, "is invalid") |> put_change(:start_amount, 1)

      is_nil(target) or is_nil(stop) ->
        changeset
        |> validate_required([:target_amount, :end_date], message: "is needed")
        |> put_change(:unit, frequency)
        |> put_change(:start_amount, 1)

      is_nil(start) ->
        put_change(changeset, :start_amount, 1)

      true ->
        periods = SavingsChallenge.Plan.periods_between(frequency, start, stop)
        changeset = put_change(changeset, :unit, frequency)

        cond do
          periods < 1 ->
            changeset |> add_error(:end_date, "must be on or after the start date") |> put_change(:start_amount, 1)

          periods > @max_periods[frequency] ->
            changeset
            |> add_error(:end_date, "is too far away to save #{every(frequency)} (max #{@max_periods[frequency]} deposits)")
            |> put_change(:start_amount, 1)

          true ->
            changeset
            |> put_change(:periods, periods)
            |> put_change(:start_amount, div(max(target, 1) + periods - 1, periods))
        end
    end
  end

  defp every("day"), do: "daily"
  defp every("week"), do: "weekly"
  defp every("month"), do: "monthly"

  # A fixed plan has no increment; a blank increment on an increasing plan means 0.
  defp normalise_fixed(changeset) do
    cond do
      get_field(changeset, :mode) == "fixed" -> put_change(changeset, :increment, 0)
      is_nil(get_field(changeset, :increment)) -> put_change(changeset, :increment, 0)
      true -> changeset
    end
  end

  @doc "A challenge struct with sensible defaults, starting today."
  def new_default, do: %__MODULE__{start_date: Clock.today(), plan: "weekly_increasing", frequency: "week"}
end
