defmodule SavingsChallenge.Plan do
  @moduledoc """
  Pure functions for the 52-week plan: weekly targets, week statuses and the
  numbers shown on the dashboard.

  Nothing here touches the database. Totals are always *derived* from the list
  of contributions, so a deposit can never be double-counted.

  A challenge only needs the keys `:mode` (`"increasing"` or `"fixed"`),
  `:start_amount`, `:increment`, `:target_amount` (nil = use projected total)
  and `:start_date`. All amounts are whole KSh.
  """

  @weeks 52

  def weeks, do: @weeks

  @doc "Planned contribution for `week` (1..52)."
  def week_target(%{mode: "fixed", start_amount: start}, _week), do: start
  def week_target(%{start_amount: start, increment: inc}, week), do: start + (week - 1) * inc

  @doc "Sum of all 52 planned contributions."
  def projected_total(challenge) do
    Enum.reduce(1..@weeks, 0, fn w, acc -> acc + week_target(challenge, w) end)
  end

  @doc "The savings goal: the custom target if set, otherwise the projected total."
  def goal(%{target_amount: target}) when is_integer(target) and target > 0, do: target
  def goal(challenge), do: projected_total(challenge)

  @doc "Current challenge week (1..52), based on the start date. Clamped at both ends."
  def current_week(%{start_date: start}, today) do
    (Date.diff(today, start) |> div(7)) + 1 |> max(1) |> min(@weeks)
  end

  @doc """
  Builds everything the UI needs from a challenge and its contributions
  (anything with `:week` and `:amount`).
  """
  def snapshot(challenge, contributions, today) do
    paid_by_week = Enum.reduce(contributions, %{}, &Map.update(&2, &1.week, &1.amount, fn a -> a + &1.amount end))
    current = current_week(challenge, today)

    weeks =
      for w <- 1..@weeks do
        target = week_target(challenge, w)
        paid = Map.get(paid_by_week, w, 0)

        %{
          week: w,
          target: target,
          paid: paid,
          status: status(w, current, paid, target),
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
      remaining_weeks: @weeks - completed,
      behind: behind,
      next: next_contribution(weeks, current),
      series: series(weeks, current)
    }
  end

  defp status(week, current, paid, target) do
    cond do
      paid >= target -> :completed
      week == current -> :current
      week < current -> :missed
      true -> :upcoming
    end
  end

  # What to put away next: the rest of this week if unpaid, else next week's target.
  defp next_contribution(weeks, current) do
    this = Enum.at(weeks, current - 1)

    cond do
      this.status != :completed -> %{week: this.week, amount: this.target - this.paid}
      current < @weeks -> %{week: current + 1, amount: Enum.at(weeks, current).target}
      true -> nil
    end
  end

  # Cumulative planned vs actual savings per week, for the chart.
  # Actual is only reported up to the current week.
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
