defmodule SavingsChallenge.SavingsTest do
  use SavingsChallenge.DataCase, async: true

  alias SavingsChallenge.{Clock, Plan, Savings}

  defp deposit(challenge, week, amount, extra \\ %{}) do
    Savings.create_contribution(
      challenge,
      Map.merge(%{"week" => week, "amount" => amount, "deposited_on" => Date.to_iso8601(Clock.today())}, extra)
    )
  end

  defp saved(challenge) do
    Plan.snapshot(challenge, Savings.list_contributions(challenge), Clock.today()).saved
  end

  test "partial and multiple deposits in one week add up" do
    ch = challenge_fixture()
    {:ok, _} = deposit(ch, 2, 30)
    {:ok, _} = deposit(ch, 2, 70)
    assert saved(ch) == 100
  end

  test "edit and delete recalculate totals" do
    ch = challenge_fixture()
    {:ok, a} = deposit(ch, 1, 50)
    {:ok, _} = deposit(ch, 1, 20)
    assert saved(ch) == 70

    {:ok, _} = Savings.update_contribution(ch, a.id, %{"amount" => 10, "deposited_on" => Date.to_iso8601(Clock.today())})
    assert saved(ch) == 30

    {:ok, _} = Savings.delete_contribution(ch, a.id)
    assert saved(ch) == 20
  end

  test "a double submit with the same idempotency key is counted once" do
    ch = challenge_fixture()
    assert {:ok, %{}} = deposit(ch, 1, 50, %{"idempotency_key" => "abc"})
    assert {:ok, :duplicate} = deposit(ch, 1, 50, %{"idempotency_key" => "abc"})
    assert saved(ch) == 50
  end

  test "validation rejects bad weeks, amounts and future dates" do
    ch = challenge_fixture()
    assert {:error, cs} = deposit(ch, 53, 10)
    assert %{week: [_]} = errors_on(cs)
    assert {:error, cs} = deposit(ch, 1, 0)
    assert %{amount: [_]} = errors_on(cs)
    future = Date.to_iso8601(Date.add(Clock.today(), 3))
    assert {:error, cs} = deposit(ch, 1, 10, %{"deposited_on" => future})
    assert %{deposited_on: ["can't be in the future"]} = errors_on(cs)
    assert saved(ch) == 0
  end

  test "changing the plan keeps deposits and recalculates targets" do
    ch = challenge_fixture()
    {:ok, _} = deposit(ch, 1, 50)
    {:ok, ch} = Savings.update_challenge(ch, %{"mode" => "fixed", "start_amount" => 200})
    assert ch.increment == 0
    snap = Plan.snapshot(ch, Savings.list_contributions(ch), Clock.today())
    assert snap.saved == 50
    assert snap.planned_total == 10_400
  end

  test "goals are independent: deposits and totals never mix" do
    trip = challenge_fixture(%{"name" => "Zanzibar trip", "category" => "trip"})
    laptop = challenge_fixture(%{"name" => "Laptop", "category" => "equipment", "mode" => "fixed", "start_amount" => 500})

    {:ok, _} = deposit(trip, 1, 50)
    {:ok, _} = deposit(laptop, 1, 500)
    {:ok, _} = deposit(laptop, 2, 200)

    assert saved(trip) == 50
    assert saved(laptop) == 700
    assert Enum.map(Savings.list_challenges(), & &1.name) == ["Zanzibar trip", "Laptop"]
    assert Savings.count_challenges() == 2
  end

  test "deleting a goal removes its deposits and leaves other goals alone" do
    a = challenge_fixture(%{"name" => "A"})
    b = challenge_fixture(%{"name" => "B"})
    {:ok, _} = deposit(a, 1, 50)
    {:ok, _} = deposit(b, 1, 50)

    {:ok, _} = Savings.delete_challenge(a)

    assert Savings.get_challenge(a.id) == nil
    assert saved(b) == 50
    assert Repo.aggregate(SavingsChallenge.Contribution, :count) == 1
  end

  test "get_challenge tolerates bad ids and unknown categories are rejected" do
    assert Savings.get_challenge("abc") == nil
    assert Savings.get_challenge("999999") == nil
    assert {:error, cs} = Savings.create_challenge(%{"category" => "yacht", "start_amount" => 50, "start_date" => "2026-01-01"})
    assert %{category: [_]} = errors_on(cs)
  end

  describe "challenge kinds" do
    test "daily plan: 100 periods, deposits allowed up to day 100" do
      ch = challenge_fixture(%{"plan" => "daily", "start_amount" => 200})
      assert {ch.kind, ch.unit, ch.periods, ch.mode} == {"daily", "day", 100, "fixed"}
      assert {:ok, _} = deposit(ch, 100, 200)
      assert {:error, cs} = deposit(ch, 101, 200)
      assert %{week: [_]} = errors_on(cs)
      assert Plan.projected_total(ch) == 20_000
    end

    test "envelope plan: 12 weeks with a stored 1..12 permutation" do
      ch = challenge_fixture(%{"plan" => "envelope", "start_amount" => 100})
      assert {ch.kind, ch.periods} == {"envelope", 12}
      assert Enum.sort(ch.multipliers) == Enum.to_list(1..12)
      assert Plan.projected_total(ch) == 7_800

      # Re-saving the plan keeps the same envelopes.
      {:ok, again} = Savings.update_challenge(ch, %{"plan" => "envelope", "start_amount" => 50})
      assert again.multipliers == ch.multipliers
      assert Plan.projected_total(again) == 3_900
    end

    test "deadline plan derives periods and the amount per deposit" do
      start = Clock.today()

      ch =
        challenge_fixture(%{
          "plan" => "deadline",
          "target_amount" => 10_000,
          "end_date" => Date.to_iso8601(Date.add(start, 29)),
          "frequency" => "day"
        })

      assert {ch.kind, ch.unit, ch.periods} == {"deadline", "day", 30}
      assert ch.start_amount == 334
      assert Plan.goal(ch) == 10_000
    end

    test "deadline plan validation" do
      today = Clock.today()
      base = %{"plan" => "deadline", "start_date" => Date.to_iso8601(today), "frequency" => "week"}

      assert {:error, cs} = Savings.create_challenge(base)
      assert %{target_amount: [_], end_date: [_]} = errors_on(cs)

      assert {:error, cs} = Savings.create_challenge(Map.merge(base, %{"target_amount" => 5000, "end_date" => Date.to_iso8601(Date.add(today, -3))}))
      assert %{end_date: [msg]} = errors_on(cs)
      assert msg =~ "on or after"

      assert {:error, cs} = Savings.create_challenge(Map.merge(base, %{"target_amount" => 5000, "end_date" => Date.to_iso8601(Date.add(today, 9000)), "frequency" => "day"}))
      assert %{end_date: [msg]} = errors_on(cs)
      assert msg =~ "too far"
    end

    test "a plan change cannot orphan existing deposits" do
      ch = challenge_fixture(%{"plan" => "daily", "start_amount" => 100})
      {:ok, _} = deposit(ch, 50, 100)

      assert {:error, cs} = Savings.update_challenge(ch, %{"plan" => "envelope", "start_amount" => 100})
      assert %{plan: [msg]} = errors_on(cs)
      assert msg =~ "period 50"

      assert {:ok, _} = Savings.update_challenge(ch, %{"plan" => "daily", "start_amount" => 150})
    end
  end

  describe "bills and subscriptions" do
    defp bill(attrs \\ %{}) do
      today = Clock.today()

      challenge_fixture(
        Map.merge(
          %{
            "plan" => "bill",
            "name" => "Netflix",
            "category" => "subscription",
            "target_amount" => 1100,
            "end_date" => Date.to_iso8601(Date.add(today, 10)),
            "frequency" => "day",
            "recurrence" => "monthly"
          },
          attrs
        )
      )
    end

    test "a bill works out the daily set-aside up to its due date" do
      b = bill()
      assert {b.kind, b.unit, b.periods, b.recurrence, b.cycle} == {"bill", "day", 11, "monthly", 1}
      assert b.start_amount == 100
      assert Plan.goal(b) == 1100
    end

    test "weekly set-aside" do
      b = bill(%{"frequency" => "week", "end_date" => Date.to_iso8601(Date.add(Clock.today(), 27)), "target_amount" => 2000})
      assert {b.unit, b.periods, b.start_amount} == {"week", 4, 500}
    end

    test "bill validation: needs amount and due date, rejects bad recurrence" do
      assert {:error, cs} = Savings.create_challenge(%{"plan" => "bill", "start_date" => Date.to_iso8601(Clock.today()), "frequency" => "day"})
      assert %{target_amount: [_], end_date: [_]} = errors_on(cs)

      assert {:error, cs} =
               Savings.create_challenge(%{
                 "plan" => "bill", "target_amount" => 500, "frequency" => "day", "recurrence" => "fortnightly",
                 "start_date" => Date.to_iso8601(Clock.today()), "end_date" => Date.to_iso8601(Date.add(Clock.today(), 5))
               })

      assert %{recurrence: [_]} = errors_on(cs)
    end

    test "marking a repeating bill paid records history and starts a fresh cycle" do
      b = bill()
      {:ok, _} = deposit(b, 1, 100)
      {:ok, _} = deposit(b, 2, 100)
      assert saved(b) == 200

      today = Clock.today()
      {:ok, b2} = Savings.mark_bill_paid(b, today)

      assert b2.cycle == 2
      assert b2.completed_at == nil
      assert b2.end_date == Plan.next_due(b.end_date, "monthly")
      assert b2.start_date == today
      assert b2.periods == Plan.periods_between("day", today, b2.end_date)
      assert b2.start_amount * b2.periods >= 1100

      # The new cycle starts empty, the old deposits are kept in the history only.
      assert Savings.list_contributions(b2) == []
      assert saved(b2) == 0
      assert Repo.aggregate(SavingsChallenge.Contribution, :count) == 2

      assert [%{cycle: 1, amount_due: 1100, saved: 200, due_date: due, paid_on: ^today}] = Savings.list_bill_payments(b2)
      assert due == b.end_date

      # New deposits belong to the new cycle.
      {:ok, c} = deposit(b2, 1, 50)
      assert c.cycle == 2
      assert saved(b2) == 50
    end

    test "extra saved beyond a repeating bill is carried into the next cycle" do
      b = bill()
      {:ok, _} = deposit(b, 1, 1_300)
      {:ok, b2} = Savings.mark_bill_paid(b, Clock.today())

      assert saved(b2) == 200
      assert [%{amount: 200, cycle: 2, note: "Carried over from last cycle"}] = Savings.list_contributions(b2)
      assert [%{cycle: 1, saved: 1_300}] = Savings.list_bill_payments(b2)

      # Paying again with nothing extra carries nothing.
      {:ok, b3} = Savings.mark_bill_paid(b2, Clock.today())
      assert Savings.list_contributions(b3) == []
    end

    test "a bill that is already overdue can be created and is due in full" do
      today = Clock.today()
      {:ok, b} = Savings.create_challenge(%{"name" => "Rent", "category" => "rent", "plan" => "bill", "target_amount" => "20000", "frequency" => "day", "recurrence" => "monthly", "start_date" => Date.to_iso8601(today), "end_date" => Date.to_iso8601(Date.add(today, -5))})
      assert b.periods == 1 and b.start_amount == 20_000

      snap = Plan.snapshot(b, [], today)
      assert snap.next == %{week: 1, amount: 20_000}

      # Part payments reduce what is still due; paying it rolls to the next future date.
      {:ok, _} = deposit(b, 1, 8_000)
      assert Plan.snapshot(b, Savings.list_contributions(b), today).next.amount == 12_000
      {:ok, b2} = Savings.mark_bill_paid(b, today)
      assert Date.compare(b2.end_date, today) in [:gt, :eq]
    end

    test "a one-off bill is completed when paid" do
      b = bill(%{"recurrence" => "once"})
      {:ok, b2} = Savings.mark_bill_paid(b, Clock.today())
      assert b2.completed_at
      assert b2.cycle == 1
      assert length(Savings.list_bill_payments(b2)) == 1
    end

    test "a bill paid very late skips past dates to the next future one" do
      today = Clock.today()
      b = bill(%{"recurrence" => "weekly", "end_date" => Date.to_iso8601(today), "frequency" => "day"})
      {:ok, late} = Savings.mark_bill_paid(%{b | end_date: Date.add(today, -20)}, today)
      assert Date.compare(late.end_date, today) in [:gt, :eq]
      assert Date.diff(late.end_date, today) <= 7
    end

    test "paying a bill twice keeps counting cycles" do
      b = bill()
      {:ok, b2} = Savings.mark_bill_paid(b, Clock.today())
      {:ok, b3} = Savings.mark_bill_paid(b2, Clock.today())
      assert b3.cycle == 3
      assert length(Savings.list_bill_payments(b3)) == 2
    end

    test "non-bills cannot be marked paid" do
      goal = challenge_fixture()
      assert_raise FunctionClauseError, fn -> Savings.mark_bill_paid(goal, Clock.today()) end
    end
  end

  test "challenge validation" do
    assert {:error, cs} = Savings.create_challenge(%{"start_amount" => -5, "start_date" => "2026-01-01"})
    assert %{start_amount: [_]} = errors_on(cs)
  end

  defp errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Regex.replace(~r"%{(\w+)}", msg, fn _, key -> opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string() end)
    end)
  end

  describe "shopping list" do
    alias SavingsChallenge.GoalItem

    test "items add up to the goal and the 52-week amounts are refitted" do
      {:ok, c} = Savings.create_challenge(%{"name" => "Home", "category" => "furniture", "plan" => "weekly_fixed", "start_amount" => "100", "start_date" => Date.to_iso8601(Clock.today())})

      {:ok, _} = Savings.add_item(c, %{"name" => "TV", "cost" => "40000"})
      {:ok, _} = Savings.add_item(c, %{"name" => "Fridge", "cost" => "52000"})
      c = Savings.get_challenge(c.id)

      assert c.target_amount == 92_000
      assert c.start_amount == 1_770
      assert Plan.goal(c) == 92_000
      assert Enum.map(Savings.list_items(c), & &1.name) == ["TV", "Fridge"]

      [tv | _] = Savings.list_items(c)
      {:ok, _} = Savings.remove_item(c, tv.id)
      c = Savings.get_challenge(c.id)
      assert c.target_amount == 52_000
      assert c.start_amount == 1_000
    end

    test "a rising 52-week plan is refitted to the total" do
      {:ok, c} = Savings.create_challenge(%{"name" => "Home", "category" => "furniture", "plan" => "weekly_increasing", "start_amount" => "50", "increment" => "50", "start_date" => Date.to_iso8601(Clock.today())})
      {:ok, _} = Savings.add_item(c, %{"name" => "Cooker", "cost" => "27560"})
      c = Savings.get_challenge(c.id)
      assert c.target_amount == 27_560
      assert c.start_amount == 20 and c.increment == 20
      assert Plan.projected_total(c) >= 27_560
    end

    test "adding an item midway leaves past weeks alone and spreads the rest ahead" do
      for plan <- ["weekly_fixed", "weekly_increasing"] do
        start = Date.add(Clock.today(), -21)
        {:ok, c} = Savings.create_challenge(%{"name" => "H", "category" => "furniture", "plan" => plan, "start_amount" => "100", "increment" => "10", "start_date" => Date.to_iso8601(start)})
        for w <- [1, 2], do: {:ok, _} = Savings.create_contribution(c, %{"week" => w, "amount" => Plan.period_target(c, w), "deposited_on" => Date.to_iso8601(Clock.today())})

        {:ok, _} = Savings.add_item(c, %{"name" => "TV", "cost" => "40000"})
        c = Savings.get_challenge(c.id)
        snap = Plan.snapshot(c, Savings.list_contributions(c), Clock.today())

        assert Enum.map(Enum.take(snap.weeks, 2), & &1.status) == [:completed, :completed], plan
        assert snap.goal == 40_000
        assert snap.behind == 0
        assert snap.projected_final == 40_000
        assert snap.next.amount > 700
      end
    end

    test "a goal-and-deadline plan keeps its dates" do
      today = Clock.today()
      {:ok, c} = Savings.create_challenge(%{"name" => "Home", "category" => "furniture", "plan" => "deadline", "target_amount" => "1000", "frequency" => "week", "start_date" => Date.to_iso8601(today), "end_date" => Date.to_iso8601(Date.add(today, 69))})
      {:ok, _} = Savings.add_item(c, %{"name" => "TV", "cost" => "10000"})
      c = Savings.get_challenge(c.id)
      assert c.target_amount == 10_000
      assert c.periods == 10 and c.start_amount == 1_000
    end

    test "savings fill the list in order, bought can be toggled" do
      items = [%GoalItem{name: "TV", cost: 1000}, %GoalItem{name: "Fridge", cost: 2000}, %GoalItem{name: "Cooker", cost: 500}]
      rows = GoalItem.allocate(items, 1500)
      assert Enum.map(rows, &{&1.funded, &1.status}) == [{1000, :funded}, {500, :partial}, {0, :waiting}]

      {:ok, c} = Savings.create_challenge(%{"name" => "Home", "category" => "furniture", "plan" => "weekly_fixed", "start_amount" => "100", "start_date" => Date.to_iso8601(Clock.today())})
      {:ok, item} = Savings.add_item(c, %{"name" => "TV", "cost" => "1000"})
      {:ok, bought} = Savings.toggle_bought(c, item.id, Clock.today())
      assert bought.bought_on == Clock.today()
      {:ok, undone} = Savings.toggle_bought(c, item.id, Clock.today())
      assert undone.bought_on == nil
    end

    test "validation, other kinds, and the size limit" do
      {:ok, c} = Savings.create_challenge(%{"name" => "Home", "category" => "furniture", "plan" => "weekly_fixed", "start_amount" => "100", "start_date" => Date.to_iso8601(Clock.today())})
      assert {:error, %Ecto.Changeset{}} = Savings.add_item(c, %{"name" => "", "cost" => "10"})
      assert {:error, %Ecto.Changeset{}} = Savings.add_item(c, %{"name" => "TV", "cost" => "0"})

      {:ok, daily} = Savings.create_challenge(%{"name" => "Daily", "category" => "general", "plan" => "daily", "start_amount" => "100", "start_date" => Date.to_iso8601(Clock.today())})
      assert {:error, %Ecto.Changeset{}} = Savings.add_item(daily, %{"name" => "TV", "cost" => "10"})

      for n <- 1..30, do: {:ok, _} = Savings.add_item(c, %{"name" => "Item #{n}", "cost" => "10"})
      assert {:error, %Ecto.Changeset{}} = Savings.add_item(c, %{"name" => "One too many", "cost" => "10"})
    end

    test "deleting a goal removes its items" do
      {:ok, c} = Savings.create_challenge(%{"name" => "Home", "category" => "furniture", "plan" => "weekly_fixed", "start_amount" => "100", "start_date" => Date.to_iso8601(Clock.today())})
      {:ok, _} = Savings.add_item(c, %{"name" => "TV", "cost" => "10"})
      {:ok, _} = Savings.delete_challenge(c)
      assert Repo.aggregate(GoalItem, :count) == 0
    end
  end

  describe "tranche goal" do
    test "needs a goal amount, then deposits of any size are accepted anytime" do
      today = Date.to_iso8601(Clock.today())
      base = %{"name" => "Car", "category" => "general", "plan" => "tranche", "start_date" => today}
      assert {:error, cs} = Savings.create_challenge(base)
      assert %{target_amount: [_]} = errors_on(cs)

      {:ok, c} = Savings.create_challenge(Map.put(base, "target_amount", "2500000"))
      assert c.kind == "tranche" and c.unit == "tranche" and c.periods == 52 and c.start_amount == 48_077

      {:ok, _} = Savings.create_contribution(c, %{"week" => 1, "amount" => "5000", "deposited_on" => today})
      {:ok, _} = Savings.create_contribution(c, %{"week" => 1, "amount" => "120000", "deposited_on" => today})
      snap = Plan.snapshot(c, Savings.list_contributions(c), Clock.today())
      assert snap.saved == 125_000 and snap.completed_weeks == 2 and snap.current_week == 3
    end
  end
end
