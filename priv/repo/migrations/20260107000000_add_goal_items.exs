defmodule SavingsChallenge.Repo.Migrations.AddGoalItems do
  use Ecto.Migration

  def change do
    create table(:goal_items) do
      add :challenge_id, references(:challenges, on_delete: :delete_all), null: false
      add :name, :string, null: false
      add :cost, :integer, null: false
      add :position, :integer, null: false, default: 0
      add :bought_on, :date

      timestamps(type: :utc_datetime)
    end

    create index(:goal_items, [:challenge_id, :position])
    create constraint(:goal_items, :cost_positive, check: "cost > 0")
  end
end
