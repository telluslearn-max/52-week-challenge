defmodule SavingsChallenge.Plan do
  @moduledoc """
  Pure functions for a savings plan: per-period targets, period statuses and the
  numbers shown on the dashboard.

  A plan is a number of *periods* (`:periods`) of a given `:unit` ("day",
  "week" or "month"). The 52-week challenge is 52 weekly periods; "Mia kwa
  Mia" is 100 daily ones; the envelope challenge is 12 weekly ones. Internally
  a period number is still called `week` in contribution rows and snapshot
  entries (the original 52-week naming); read it as "period".

  Nothing here touches the database. Totals are always *derived* from the list
  of contributions, so a deposit can never be double-counted.

  A challenge needs `:mode` ("increasing" | "fixed"), `:start_amount`,
  `:increment`, `:target_amount` (nil = use projected total) and `:start_date`.
  Optional (defaults in brackets): `:kind` (["weekly"] | "daily" | "envelope" |
  "deadline"), `:unit` (["week"]), `:periods` ([52]) and `:multipliers`
  (envelope only: the 1..12 multiplier for each period). Amounts are whole KSh.
  """

  @weeks 52

  @doc "Length of the classic 52-week challenge."
  def weeks, do: @weeks

  def periods(c), do: Map.get(c, :periods) || @weeks
  def unit(c), do: Map.get(c, :unit) || "week"
  def kind(c), do: Map.get(c, :kind) || "weekly"

  @doc "Planned contribution for period `p` (1-based)."
  def period_target(c, p) do
    cond do
      kind(c) == "envelope" -> c.start_amount * (Enum.at(Map.get(c, :multipliers) || [], p - 1) || 1)
      c.mode == "fixed" -> c.start_amount
      true -> c.start_amount + (p - 1) * c.increment
    end
  end

  @doc "Sum of all planned contributions."
  def projected_total(c) do
    Enum.reduce(1..periods(c), 0, fn p, acc -> acc + period_target(c, p) end)
  end

  @doc "The savings goal: the custom target if set, otherwise the projected total."
  def goal(%{target_amount: target}) when is_integer(target) and target > 0, do: target
  def goal(challenge), do: projected_total(challenge)

  @doc "Current period (1..periods), based on the start date. Clamped at both ends."
  def current_week(c, today) do
    (elapsed(unit(c), c.start_date, today) + 1) |> max(1) |> min(periods(c))
  end

  @doc "Whole periods elapsed between `start` and `today` (negative before the start)."
  def elapsed("day", start, today), do: Date.diff(today, start)
  def elapsed("month", start, today), do: month_diff(start, today)
  def elapsed(_week, start, today), do: div(Date.diff(today, start), 7)

  @doc "How many periods fit from `start` to `stop` inclusive (0 if `stop` is before `start`)."
  def periods_between(_unit, start, stop) when is_nil(start) or is_nil(stop), do: 0

  def periods_between(unit, start, stop) do
    if Date.compare(stop, start) == :lt, do: 0, else: elapsed(unit, start, stop) + 1
  end

  @doc "First day of period `p`."
  def period_start(c, p) do
    case unit(c) do
      "day" -> Date.add(c.start_date, p - 1)
      "month" -> add_months(c.start_date, p - 1)
      _ -> Date.add(c.start_date, (p - 1) * 7)
    end
  end

  # Largest n such that `add_months(from, n) <= to`, so it agrees with period_start/2.
  defp month_diff(from, to) do
    months = (to.year - from.year) * 12 + (to.month - from.month)

    cond do
      months < 0 -> months
      Date.compare(add_months(from, months), to) == :gt -> months - 1
      true -> months
    end
  end

  defp add_months(date, n) do
    total = date.year * 12 + (date.month - 1) + n
    {year, month} = {div(total, 12), rem(total, 12) + 1}
    day = min(date.day, Date.days_in_month(Date.new!(year, month, 1)))
    Date.new!(year, month, day)
  end

  @doc """
  Builds everything the UI needs from a challenge and its contributions
  (anything with `:week` and `:amount`).
  """
  def snapshot(challenge, contributions, today) do
    count = periods(challenge)
    kind = kind(challenge)
    paid_by_period = Enum.reduce(contributions, %{}, &Map.update(&2, &1.week, &1.amount, fn a -> a + &1.amount end))
    current = current_week(challenge, today)

    weeks =
      for w <- 1..count do
        target = period_target(challenge, w)
        paid = Map.get(paid_by_period, w, 0)
        status = status(w, current, paid, target)

        %{
          week: w,
          target: target,
          paid: paid,
          status: status,
          # Envelope amounts stay a surprise until their week starts.
          hidden: kind == "envelope" and status == :upcoming,
          fill: min(100, div(paid * 100, max(target, 1)))
        }
      end

    saved = Enum.reduce(weeks, 0, &(&1.paid + &2))
    goal = goal(challenge)
    planned_total = Enum.reduce(weeks, 0, &(&1.target + &2))
    outstanding = Enum.reduce(weeks, 0, &(max(&1.target - &1.paid, 0) + &2))
    completed = Enum.count(weeks, &(&1.status == :completed))
    behind = for(%{status: :missed} = w <- weeks, reduce: 0, do: (acc -> acc + w.target - w.paid))

    %{
      weeks: weeks,
      count: count,
      unit: unit(challenge),
      kind: kind,
      current_week: current,
      saved: saved,
      goal: goal,
      percent: min(100, div(saved * 100, max(goal, 1))),
      remaining: max(goal - saved, 0),
      goal_reached?: saved >= goal,
      planned_total: planned_total,
      outstanding: outstanding,
      projected_final: saved + outstanding,
      completed_weeks: completed,
      remaining_weeks: count - completed,
      behind: behind,
      next: next_contribution(weeks, current, count),
      series: series(weeks, current)
    }
  end

  defp status(period, current, paid, target) do
    cond do
      paid >= target -> :completed
      period == current -> :current
      period < current -> :missed
      true -> :upcoming
    end
  end

  # What to put away next: the rest of this period if unpaid, else the next one.
  defp next_contribution(weeks, current, count) do
    this = Enum.at(weeks, current - 1)

    cond do
      this.status != :completed -> %{week: this.week, amount: this.target - this.paid}
      current < count -> %{week: current + 1, amount: Enum.at(weeks, current).target}
      true -> nil
    end
  end

  # Cumulative planned vs actual savings per period, for the chart.
  # Actual is only reported up to the current period.
  defp series(weeks, current) do
    {rows, _} =
      Enum.map_reduce(weeks, {0, 0}, fn w, {plan, actual} ->
        plan = plan + w.target
        actual = actual + w.paid
        {%{week: w.week, plan: plan, actual: if(w.week <= current, do: actual)}, {plan, actual}}
      end)

    rows
  end
end
