defmodule SavingsChallenge.Repo.Migrations.AddDebts do
  use Ecto.Migration

  def up do
    create table(:debts) do
      add :name, :string, null: false
      add :amount, :integer, null: false
      add :paid_amount, :integer, null: false, default: 0
      add :paid_on, :date

      timestamps(type: :utc_datetime)
    end

    create constraint(:debts, :debt_amount_positive, check: "amount > 0")
    create constraint(:debts, :debt_paid_in_range, check: "paid_amount >= 0 and paid_amount <= amount")

    # Money paid out of a savings pool is stored as a negative "deposit" on that pool.
    alter table(:contributions) do
      add :debt_id, references(:debts, on_delete: :nilify_all)
    end

    create index(:contributions, [:debt_id])
    drop constraint(:contributions, :amount_positive)
    create constraint(:contributions, :amount_nonzero, check: "amount <> 0")
  end

  def down do
    execute "delete from contributions where amount < 0"
    drop constraint(:contributions, :amount_nonzero)
    create constraint(:contributions, :amount_positive, check: "amount > 0")

    alter table(:contributions) do
      remove :debt_id
    end

    drop table(:debts)
  end
end
