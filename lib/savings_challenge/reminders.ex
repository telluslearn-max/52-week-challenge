defmodule SavingsChallenge.Reminders do
  @moduledoc """
  The daily "time to save" notification.

  `digest/2` is pure (goals + today in, message out). `run_daily/0` is called by
  the external scheduler; a once-a-day guard makes repeated calls harmless.
  """
  import Ecto.Query

  alias SavingsChallenge.{AppSettings, Clock, Lock, Plan, Push, Repo, Savings}

  @soon_days 3

  ## Pure part

  @doc """
  `goals` is a list of `%{challenge: _, snap: _}`. Returns
  `%{items: [...], total: n, due_soon: [...]}`; both lists empty means nothing to say.
  """
  def digest(goals, today) do
    active = Enum.filter(goals, &(is_nil(&1.challenge.completed_at) and not &1.snap.goal_reached?))

    items =
      for %{challenge: c, snap: %{next: %{} = next} = s} <- active,
          next.week == s.current_week,
          next.amount > 0 do
        %{name: c.name, amount: next.amount, unit: s.unit}
      end

    due_soon =
      for %{challenge: %{kind: "bill"} = c} <- active,
          days = Date.diff(c.end_date, today),
          days in 0..@soon_days,
          do: %{name: c.name, days: days}

    %{items: items, total: Enum.sum(Enum.map(items, & &1.amount)), due_soon: due_soon}
  end

  @doc "Turns a digest into the notification payload, or nil if there is nothing to say."
  def message(%{items: [], due_soon: []}), do: nil

  def message(%{items: items, total: total, due_soon: due_soon}) do
    lines =
      Enum.map(items, &"KSh #{num(&1.amount)} · #{&1.name}") ++
        Enum.map(due_soon, &"#{&1.name} is #{due_phrase(&1.days)}")

    title = if items == [], do: "A bill is due soon", else: "Time to save: KSh #{num(total)} today"
    %{title: title, body: Enum.join(lines, "\n"), url: "/", tag: "daily-reminder"}
  end

  defp due_phrase(0), do: "due today"
  defp due_phrase(1), do: "due tomorrow"
  defp due_phrase(n), do: "due in #{n} days"

  defp num(n), do: SavingsChallengeWeb.Format.num(n)

  ## Settings

  def settings, do: Lock.get()

  def update_settings(attrs) do
    Lock.get() |> Ecto.Changeset.cast(attrs, [:reminders_enabled, :reminder_hour]) |> Ecto.Changeset.validate_inclusion(:reminder_hour, 0..23) |> Repo.update()
  end

  ## Running

  def current_digest(today \\ Clock.today()) do
    goals =
      for challenge <- Savings.list_challenges() do
        %{challenge: challenge, snap: Plan.snapshot(challenge, Savings.current_contributions(challenge), today)}
      end

    digest(goals, today)
  end

  @doc """
  Sends today's reminder if it is due: enabled, past the chosen hour, devices
  registered, something to say, and not already sent today. At most once per day.
  """
  def run_daily(now \\ Clock.local_now()) do
    today = DateTime.to_date(now)

    cond do
      not Push.enabled?() -> {:skipped, :push_not_configured}
      Push.count() == 0 -> {:skipped, :no_devices}
      true -> claim_and_send(now, today)
    end
  end

  # The row lock makes concurrent pings from the scheduler safe: only one claims the day.
  defp claim_and_send(now, today) do
    claim =
      Repo.transaction(fn ->
        # Make sure the single settings row exists (it is created lazily).
        _ = Lock.get()
        s = Repo.one!(from a in AppSettings, where: a.id == 1, lock: "FOR UPDATE")

        cond do
          not s.reminders_enabled -> {:skipped, :disabled}
          now.hour < s.reminder_hour -> {:skipped, :too_early}
          s.last_reminder_on == today -> {:skipped, :already_sent}
          true -> s |> Ecto.Changeset.change(last_reminder_on: today) |> Repo.update!() && :claimed
        end
      end)

    case claim do
      {:ok, :claimed} ->
        case message(current_digest(today)) do
          nil -> {:skipped, :nothing_to_save}
          msg -> {:sent, Push.broadcast(msg)}
        end

      {:ok, skipped} ->
        skipped
    end
  end

  def send_test do
    Push.broadcast(%{title: "Notifications are on", body: "You'll get a reminder like this when it's time to save.", url: "/", tag: "test"})
  end
end
