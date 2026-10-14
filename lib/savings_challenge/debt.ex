defmodule SavingsChallenge.Debt do
  @moduledoc """
  Money you owe someone. A debt is cleared by paying it, either out of a
  savings pool (a 52-tranche goal, which then goes down by that amount) or from
  money kept elsewhere. Part payments are fine: the debt is paid once the
  payments add up to the amount.
  """
  use Ecto.Schema
  import Ecto.Changeset

  schema "debts" do
    field :name, :string
    field :amount, :integer
    field :paid_amount, :integer, default: 0
    field :paid_on, :date

    timestamps(type: :utc_datetime)
  end

  def changeset(debt, attrs) do
    debt
    |> cast(attrs, [:name, :amount])
    |> update_change(:name, &String.trim/1)
    |> validate_required([:name, :amount], message: "is needed")
    |> validate_length(:name, max: 60)
    |> validate_number(:amount, greater_than: 0, less_than_or_equal_to: 100_000_000)
  end

  def remaining(%__MODULE__{amount: amount, paid_amount: paid}), do: amount - paid
  def paid?(%__MODULE__{paid_on: paid_on}), do: not is_nil(paid_on)
end
