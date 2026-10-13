defmodule SavingsChallenge.Repo.Migrations.AddBills do
  use Ecto.Migration

  def up do
    alter table(:challenges) do
      add :recurrence, :string, null: false, default: "once"
      add :cycle, :integer, null: false, default: 1
    end

    alter table(:contributions) do
      add :cycle, :integer, null: false, default: 1
    end

    drop constraint(:challenges, :kind_valid)
    create constraint(:challenges, :kind_valid, check: "kind in ('weekly', 'daily', 'envelope', 'deadline', 'bill')")
    create constraint(:challenges, :recurrence_valid, check: "recurrence in ('once', 'weekly', 'monthly', 'quarterly', 'yearly')")

    create table(:bill_payments) do
      add :challenge_id, references(:challenges, on_delete: :delete_all), null: false
      add :cycle, :integer, null: false
      add :due_date, :date, null: false
      add :amount_due, :integer, null: false
      add :saved, :integer, null: false
      add :paid_on, :date, null: false

      timestamps(type: :utc_datetime)
    end

    create index(:bill_payments, [:challenge_id, :cycle])
    create index(:contributions, [:challenge_id, :cycle])
  end

  def down do
    drop table(:bill_payments)
    drop constraint(:challenges, :recurrence_valid)
    drop constraint(:challenges, :kind_valid)
    create constraint(:challenges, :kind_valid, check: "kind in ('weekly', 'daily', 'envelope', 'deadline')")

    alter table(:contributions) do
      remove :cycle
    end

    alter table(:challenges) do
      remove :cycle
      remove :recurrence
    end
  end
end
