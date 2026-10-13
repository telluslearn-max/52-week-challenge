defmodule SavingsChallenge.Repo.Migrations.AddChallengeKinds do
  use Ecto.Migration

  def up do
    alter table(:challenges) do
      add :kind, :string, null: false, default: "weekly"
      add :unit, :string, null: false, default: "week"
      add :periods, :integer, null: false, default: 52
      add :multipliers, {:array, :integer}, null: false, default: []
      add :end_date, :date
    end

    create constraint(:challenges, :kind_valid, check: "kind in ('weekly', 'daily', 'envelope', 'deadline')")
    create constraint(:challenges, :unit_valid, check: "unit in ('day', 'week', 'month')")
    create constraint(:challenges, :periods_in_range, check: "periods between 1 and 366")

    # Contributions now belong to a period (day/week/month), up to 366 of them.
    drop constraint(:contributions, :week_in_range)
    create constraint(:contributions, :week_in_range, check: "week between 1 and 366")
  end

  def down do
    drop constraint(:contributions, :week_in_range)
    create constraint(:contributions, :week_in_range, check: "week between 1 and 52")

    drop constraint(:challenges, :periods_in_range)
    drop constraint(:challenges, :unit_valid)
    drop constraint(:challenges, :kind_valid)

    alter table(:challenges) do
      remove :end_date
      remove :multipliers
      remove :periods
      remove :unit
      remove :kind
    end
  end
end
