defmodule SavingsChallenge.Repo.Migrations.CreateChallengesAndContributions do
  use Ecto.Migration

  def change do
    create table(:challenges) do
      add :name, :string, null: false, default: "My 52-week challenge"
      add :mode, :string, null: false, default: "increasing"
      add :start_amount, :integer, null: false
      add :increment, :integer, null: false, default: 0
      add :target_amount, :integer
      add :start_date, :date, null: false

      timestamps(type: :utc_datetime)
    end

    create constraint(:challenges, :mode_valid, check: "mode in ('increasing', 'fixed')")
    create constraint(:challenges, :start_amount_positive, check: "start_amount > 0")
    create constraint(:challenges, :increment_non_negative, check: "increment >= 0")
    create constraint(:challenges, :target_positive, check: "target_amount is null or target_amount > 0")

    create table(:contributions) do
      add :challenge_id, references(:challenges, on_delete: :delete_all), null: false
      add :week, :integer, null: false
      add :amount, :integer, null: false
      add :deposited_on, :date, null: false
      add :note, :string
      add :idempotency_key, :string

      timestamps(type: :utc_datetime)
    end

    create constraint(:contributions, :week_in_range, check: "week between 1 and 52")
    create constraint(:contributions, :amount_positive, check: "amount > 0")
    create index(:contributions, [:challenge_id, :week])
    create unique_index(:contributions, [:challenge_id, :idempotency_key])
  end
end
