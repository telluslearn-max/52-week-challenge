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

  test "challenge validation" do
    assert {:error, cs} = Savings.create_challenge(%{"start_amount" => -5, "start_date" => "2026-01-01"})
    assert %{start_amount: [_]} = errors_on(cs)
  end

  defp errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Regex.replace(~r"%{(\w+)}", msg, fn _, key -> opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string() end)
    end)
  end
end
