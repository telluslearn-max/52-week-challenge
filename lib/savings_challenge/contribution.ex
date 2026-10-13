defmodule SavingsChallenge.Contribution do
  use Ecto.Schema
  import Ecto.Changeset

  alias SavingsChallenge.{Challenge, Clock}

  schema "contributions" do
    field :week, :integer
    field :amount, :integer
    field :deposited_on, :date
    field :note, :string
    # Random token minted when the deposit form is rendered; a double submit
    # carries the same token and is rejected by a unique index.
    field :idempotency_key, :string
    # Bills: which cycle (1st bill, 2nd bill, ...) this deposit belongs to.
    field :cycle, :integer, default: 1

    belongs_to :challenge, Challenge

    timestamps(type: :utc_datetime)
  end

  # `max_period` is the challenge's number of periods (52 weeks, 100 days, ...).
  def changeset(contribution, attrs, max_period \\ 366) do
    contribution
    |> cast(attrs, [:week, :amount, :deposited_on, :note, :idempotency_key])
    |> update_change(:note, &String.trim/1)
    |> validate_required([:week, :amount, :deposited_on])
    |> validate_number(:week, greater_than_or_equal_to: 1, less_than_or_equal_to: max_period)
    |> validate_number(:amount, greater_than: 0, less_than_or_equal_to: 100_000_000)
    |> validate_length(:note, max: 120)
    |> validate_not_future(:deposited_on)
    |> unique_constraint(:idempotency_key, name: :contributions_challenge_id_idempotency_key_index)
    |> check_constraint(:amount, name: :amount_positive)
    |> check_constraint(:week, name: :week_in_range)
  end

  defp validate_not_future(changeset, field) do
    validate_change(changeset, field, fn _, date ->
      if Date.compare(date, Clock.today()) == :gt, do: [{field, "can't be in the future"}], else: []
    end)
  end
end
