defmodule SavingsChallenge.GoalItem do
  @moduledoc """
  One thing on a goal's shopping list (TV, fridge, cooker...). The goal's total
  is the sum of the item costs. Savings fill the items in list order, so the
  first item is funded first; nothing about funding is stored, it is derived.
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias SavingsChallenge.Challenge

  schema "goal_items" do
    field :name, :string
    field :cost, :integer
    field :position, :integer, default: 0
    field :bought_on, :date

    belongs_to :challenge, Challenge

    timestamps(type: :utc_datetime)
  end

  def changeset(item, attrs) do
    item
    |> cast(attrs, [:name, :cost])
    |> update_change(:name, &String.trim/1)
    |> validate_required([:name, :cost], message: "is needed")
    |> validate_length(:name, max: 60)
    |> validate_number(:cost, greater_than: 0, less_than_or_equal_to: 10_000_000)
    |> check_constraint(:cost, name: :cost_positive)
  end

  @doc """
  Spreads `saved` over the items in order. Each entry is
  `%{item: item, funded: ksh, status: :funded | :partial | :waiting}`.
  """
  def allocate(items, saved) do
    {rows, _left} =
      Enum.map_reduce(items, max(saved, 0), fn item, left ->
        funded = min(item.cost, left)
        status = if funded >= item.cost, do: :funded, else: if(funded > 0, do: :partial, else: :waiting)
        {%{item: item, funded: funded, status: status}, left - funded}
      end)

    rows
  end
end
