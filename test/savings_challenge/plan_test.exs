defmodule SavingsChallenge.PlanTest do
  use ExUnit.Case, async: true

  alias SavingsChallenge.Plan

  @start ~D[2026-01-05]
  @inc %{mode: "increasing", start_amount: 50, increment: 50, target_amount: nil, start_date: @start}
  @fixed %{mode: "fixed", start_amount: 200, increment: 0, target_amount: nil, start_date: @start}

  defp c(week, amount), do: %{week: week, amount: amount}

  test "increasing plan targets and projected total" do
    assert Plan.week_target(@inc, 1) == 50
    assert Plan.week_target(@inc, 2) == 100
    assert Plan.week_target(@inc, 52) == 2600
    # 50 * (1 + 2 + ... + 52)
    assert Plan.projected_total(@inc) == 68_900
  end

  test "fixed plan" do
    assert Plan.week_target(@fixed, 30) == 200
    assert Plan.projected_total(@fixed) == 10_400
  end

  test "goal uses custom target when set" do
    assert Plan.goal(@inc) == 68_900
    assert Plan.goal(%{@inc | target_amount: 50_000}) == 50_000
  end

  test "current week is clamped to 1..52" do
    assert Plan.current_week(@inc, ~D[2025-12-01]) == 1
    assert Plan.current_week(@inc, ~D[2026-01-05]) == 1
    assert Plan.current_week(@inc, ~D[2026-01-11]) == 1
    assert Plan.current_week(@inc, ~D[2026-01-12]) == 2
    assert Plan.current_week(@inc, ~D[2030-01-01]) == 52
  end

  test "statuses: completed, current, missed, upcoming" do
    # today is in week 4; weeks 1 paid, 2 partial, 3 nothing
    snap = Plan.snapshot(@inc, [c(1, 50), c(2, 40)], ~D[2026-01-26])
    status = fn w -> Enum.at(snap.weeks, w - 1).status end

    assert snap.current_week == 4
    assert status.(1) == :completed
    assert status.(2) == :missed
    assert status.(3) == :missed
    assert status.(4) == :current
    assert status.(5) == :upcoming
    assert snap.behind == 60 + 150
  end

  test "totals are derived from contributions, multiple deposits per week add up" do
    snap = Plan.snapshot(@inc, [c(2, 30), c(2, 70), c(1, 50)], ~D[2026-01-12])

    assert Enum.at(snap.weeks, 1).paid == 100
    assert Enum.at(snap.weeks, 1).status == :completed
    assert snap.saved == 150
    assert snap.completed_weeks == 2
    assert snap.remaining_weeks == 50
    assert snap.remaining == 68_900 - 150
    assert snap.outstanding == 68_900 - 150
    assert snap.projected_final == 68_900
  end

  test "overpaying counts toward saved but not against outstanding of other weeks" do
    snap = Plan.snapshot(@inc, [c(1, 500)], ~D[2026-01-05])
    assert snap.saved == 500
    assert snap.outstanding == 68_900 - 50
    assert snap.projected_final == 500 + 68_900 - 50
  end

  test "percent is capped and goal_reached? flips" do
    goal = %{@inc | target_amount: 100}
    snap = Plan.snapshot(goal, [c(1, 150)], ~D[2026-01-05])
    assert snap.percent == 100
    assert snap.goal_reached?
    assert snap.remaining == 0
  end

  test "next contribution" do
    snap = Plan.snapshot(@inc, [c(1, 20)], ~D[2026-01-05])
    assert snap.next == %{week: 1, amount: 30}

    snap = Plan.snapshot(@inc, [c(1, 50)], ~D[2026-01-05])
    assert snap.next == %{week: 2, amount: 100}

    full = for w <- 1..52, do: c(w, Plan.week_target(@inc, w))
    assert Plan.snapshot(@inc, full, ~D[2027-06-01]).next == nil
  end

  test "series: plan always, actual only up to the current week" do
    snap = Plan.snapshot(@inc, [c(1, 50)], ~D[2026-01-12])
    assert Enum.at(snap.series, 0) == %{week: 1, plan: 50, actual: 50}
    assert Enum.at(snap.series, 1) == %{week: 2, plan: 150, actual: 50}
    assert Enum.at(snap.series, 2).actual == nil
    assert List.last(snap.series).plan == 68_900
  end
end
