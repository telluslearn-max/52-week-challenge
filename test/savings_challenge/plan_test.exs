defmodule SavingsChallenge.PlanTest do
  use ExUnit.Case, async: true

  alias SavingsChallenge.Plan

  @start ~D[2026-01-05]
  @inc %{mode: "increasing", start_amount: 50, increment: 50, target_amount: nil, start_date: @start}
  @fixed %{mode: "fixed", start_amount: 200, increment: 0, target_amount: nil, start_date: @start}

  defp c(week, amount), do: %{week: week, amount: amount}

  test "increasing plan targets and projected total" do
    assert Plan.period_target(@inc, 1) == 50
    assert Plan.period_target(@inc, 2) == 100
    assert Plan.period_target(@inc, 52) == 2600
    # 50 * (1 + 2 + ... + 52)
    assert Plan.projected_total(@inc) == 68_900
  end

  test "fixed plan" do
    assert Plan.period_target(@fixed, 30) == 200
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

    full = for w <- 1..52, do: c(w, Plan.period_target(@inc, w))
    assert Plan.snapshot(@inc, full, ~D[2027-06-01]).next == nil
  end

  test "series: plan always, actual only up to the current week" do
    snap = Plan.snapshot(@inc, [c(1, 50)], ~D[2026-01-12])
    assert Enum.at(snap.series, 0) == %{week: 1, plan: 50, actual: 50}
    assert Enum.at(snap.series, 1) == %{week: 2, plan: 150, actual: 50}
    assert Enum.at(snap.series, 2).actual == nil
    assert List.last(snap.series).plan == 68_900
  end

  describe "other challenge kinds" do
    test "100-day daily challenge (Mia kwa Mia)" do
      c = %{kind: "daily", unit: "day", periods: 100, mode: "fixed", start_amount: 100, increment: 0, target_amount: nil, start_date: @start}
      assert Plan.projected_total(c) == 10_000
      assert Plan.current_week(c, ~D[2026-01-05]) == 1
      assert Plan.current_week(c, ~D[2026-01-14]) == 10
      assert Plan.current_week(c, ~D[2027-01-01]) == 100

      snap = Plan.snapshot(c, [c(1, 100), c(2, 60)], ~D[2026-01-07])
      assert snap.count == 100 and snap.unit == "day"
      assert length(snap.weeks) == 100
      assert Enum.map(Enum.take(snap.weeks, 3), & &1.status) == [:completed, :missed, :current]
      assert snap.goal == 10_000
      assert snap.next == %{week: 3, amount: 100}
    end

    test "envelope challenge multiplies the base and hides upcoming weeks" do
      mult = [3, 1, 12, 5, 9, 2, 7, 11, 4, 10, 6, 8]
      c = %{kind: "envelope", unit: "week", periods: 12, multipliers: mult, mode: "fixed", start_amount: 100, increment: 0, target_amount: nil, start_date: @start}

      assert Plan.period_target(c, 1) == 300
      assert Plan.period_target(c, 3) == 1200
      assert Plan.projected_total(c) == 100 * 78

      snap = Plan.snapshot(c, [], ~D[2026-01-12])
      assert snap.count == 12
      statuses = Enum.map(snap.weeks, &{&1.week, &1.status, &1.hidden})
      assert {1, :missed, false} in statuses
      assert {2, :current, false} in statuses
      assert {3, :upcoming, true} in statuses
    end

    test "monthly periods use calendar months" do
      c = %{kind: "deadline", unit: "month", periods: 6, mode: "fixed", start_amount: 1000, increment: 0, target_amount: 6000, start_date: ~D[2026-01-31]}
      assert Plan.period_start(c, 1) == ~D[2026-01-31]
      assert Plan.period_start(c, 2) == ~D[2026-02-28]
      assert Plan.period_start(c, 3) == ~D[2026-03-31]
      assert Plan.current_week(c, ~D[2026-02-27]) == 1
      assert Plan.current_week(c, ~D[2026-02-28]) == 2
      assert Plan.current_week(c, ~D[2030-01-01]) == 6
    end

    test "periods_between counts inclusive periods" do
      assert Plan.periods_between("day", ~D[2026-01-01], ~D[2026-01-10]) == 10
      assert Plan.periods_between("week", ~D[2026-01-01], ~D[2026-01-29]) == 5
      assert Plan.periods_between("month", ~D[2026-01-15], ~D[2026-06-14]) == 5
      assert Plan.periods_between("day", ~D[2026-01-10], ~D[2026-01-01]) == 0
      assert Plan.periods_between("day", nil, ~D[2026-01-01]) == 0
    end
  end

  describe "streaks and badges" do
    # Weekly plan from @start; fill weeks 1..n with exact targets.
    defp paid(weeks), do: for(w <- weeks, do: c(w, Plan.period_target(@inc, w)))

    test "an unfinished current period does not break the streak" do
      today = Date.add(@start, 5 * 7)
      snap = Plan.snapshot(@inc, paid([1, 2, 3, 4, 5]), today)
      assert snap.current_week == 6
      assert snap.streak == 5 and snap.best_streak == 5

      snap = Plan.snapshot(@inc, paid([1, 2, 3, 4, 5, 6]), today)
      assert snap.streak == 6
    end

    test "a missed period resets the current streak but not the best one" do
      today = Date.add(@start, 6 * 7)
      snap = Plan.snapshot(@inc, paid([1, 2, 3, 5, 6]), today)
      assert snap.current_week == 7
      assert snap.best_streak == 3
      assert snap.streak == 2
    end

    test "no deposits means no streak" do
      snap = Plan.snapshot(@inc, [], Date.add(@start, 14))
      assert {snap.streak, snap.best_streak} == {0, 0}
    end

    test "badges are derived from the snapshot" do
      alias SavingsChallenge.Badges
      earned = fn snap -> for(b <- Badges.all(snap), b.earned?, do: b.key) end

      assert earned.(Plan.snapshot(@inc, [], @start)) == []
      assert earned.(Plan.snapshot(@inc, [c(1, 10)], @start)) == ["first"]
      assert earned.(Plan.snapshot(@inc, [c(1, 60)], @start)) == ["first", "ahead"]

      snap = Plan.snapshot(@inc, paid(1..4), Date.add(@start, 21))
      keys = earned.(snap)
      assert "streak3" in keys and "ahead" not in keys

      small = %{@inc | target_amount: 100}
      assert "done" in earned.(Plan.snapshot(small, [c(1, 100)], @start))
    end
  end
end
