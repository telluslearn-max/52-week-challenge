defmodule SavingsChallenge.BillPayment do
  use Ecto.Schema

  schema "bill_payments" do
    field :cycle, :integer
    field :due_date, :date
    field :amount_due, :integer
    field :saved, :integer
    field :paid_on, :date

    belongs_to :challenge, SavingsChallenge.Challenge

    timestamps(type: :utc_datetime)
  end
end
