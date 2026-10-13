defmodule SavingsChallenge.AppSettings do
  use Ecto.Schema

  schema "app_settings" do
    field :pin_hash, :string
    field :pin_salt, :string
    field :pin_length, :integer, default: 4
    field :failed_attempts, :integer, default: 0
    field :locked_until, :utc_datetime
    field :recovery_email, :string
    field :reset_token_hash, :string
    field :reset_expires_at, :utc_datetime
    field :reset_sent_at, :utc_datetime
    field :reminders_enabled, :boolean, default: true
    field :reminder_hour, :integer, default: 8
    field :last_reminder_on, :date

    timestamps(type: :utc_datetime)
  end
end
