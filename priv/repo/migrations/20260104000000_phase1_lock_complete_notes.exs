defmodule SavingsChallenge.Repo.Migrations.Phase1LockCompleteNotes do
  use Ecto.Migration

  def change do
    alter table(:challenges) do
      add :completed_at, :utc_datetime
      add :kept_in, :string
    end

    # Single-row table (id = 1): the app-wide PIN, its lockout state and reset token.
    create table(:app_settings) do
      add :pin_hash, :string
      add :pin_salt, :string
      add :pin_length, :integer, null: false, default: 4
      add :failed_attempts, :integer, null: false, default: 0
      add :locked_until, :utc_datetime
      add :recovery_email, :string
      add :reset_token_hash, :string
      add :reset_expires_at, :utc_datetime
      add :reset_sent_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create constraint(:app_settings, :pin_length_valid, check: "pin_length in (4, 6)")
  end
end
