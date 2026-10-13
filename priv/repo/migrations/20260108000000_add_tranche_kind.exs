defmodule SavingsChallenge.Repo.Migrations.AddTrancheKind do
  use Ecto.Migration

  def up do
    drop constraint(:challenges, :kind_valid)
    create constraint(:challenges, :kind_valid, check: "kind in ('weekly', 'daily', 'envelope', 'deadline', 'bill', 'tranche')")
    drop constraint(:challenges, :unit_valid)
    create constraint(:challenges, :unit_valid, check: "unit in ('day', 'week', 'month', 'tranche')")
  end

  def down do
    execute "update challenges set kind = 'weekly', unit = 'week' where kind = 'tranche'"
    drop constraint(:challenges, :unit_valid)
    create constraint(:challenges, :unit_valid, check: "unit in ('day', 'week', 'month')")
    drop constraint(:challenges, :kind_valid)
    create constraint(:challenges, :kind_valid, check: "kind in ('weekly', 'daily', 'envelope', 'deadline', 'bill')")
  end
end
