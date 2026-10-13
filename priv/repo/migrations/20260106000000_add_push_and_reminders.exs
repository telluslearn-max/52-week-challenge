defmodule SavingsChallenge.Repo.Migrations.AddPushAndReminders do
  use Ecto.Migration

  def change do
    create table(:push_subscriptions) do
      add :endpoint, :text, null: false
      add :p256dh, :string, null: false
      add :auth, :string, null: false
      add :user_agent, :string

      timestamps(type: :utc_datetime)
    end

    create unique_index(:push_subscriptions, [:endpoint])

    alter table(:app_settings) do
      add :reminders_enabled, :boolean, null: false, default: true
      # Local (Nairobi) hour of day at which the daily reminder is sent.
      add :reminder_hour, :integer, null: false, default: 8
      add :last_reminder_on, :date
    end

    create constraint(:app_settings, :reminder_hour_valid, check: "reminder_hour between 0 and 23")
  end
end
