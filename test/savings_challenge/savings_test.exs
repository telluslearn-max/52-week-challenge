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
