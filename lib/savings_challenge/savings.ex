defmodule SavingsChallenge.Savings do
  @moduledoc """
  Context for the challenge and its contributions.

  Every write runs in a transaction that first locks the challenge row, so
  concurrent writes for the same challenge are serialised. Totals are never
  stored: they are computed from the contributions (see `Plan.snapshot/3`),
  which is what keeps them accurate after edits and deletes.
  """
  import Ecto.Query

  alias SavingsChallenge.{BillPayment, Challenge, Contribution, Debt, GoalItem, Plan, Repo}

  ## Challenge

  # Single-user prototype: every goal is visible; there are no accounts.
  def get_challenge(id) do
    case Ecto.Type.cast(:id, id) do
      {:ok, id} -> Repo.get(Challenge, id)
      :error -> nil
    end
  end

  @doc "All goals (oldest first) with their contributions preloaded."
  def list_challenges do
    Repo.all(from c in Challenge, order_by: [asc: c.id], preload: [:contributions])
  end

  @doc "Marks a goal complete (only once its goal is reached; the caller checks)."
  def complete_challenge(%Challenge{} = challenge) do
    locked(challenge.id, fn locked ->
      locked |> Ecto.Changeset.change(completed_at: DateTime.utc_now() |> DateTime.truncate(:second)) |> Repo.update()
    end)
  end

  def reopen_challenge(%Challenge{} = challenge) do
    locked(challenge.id, fn locked -> locked |> Ecto.Changeset.change(completed_at: nil) |> Repo.update() end)
  end

  def count_challenges, do: Repo.aggregate(Challenge, :count)

  @doc "Deletes a goal; its contributions are removed by the database (on_delete: :delete_all)."
  def delete_challenge(%Challenge{} = challenge), do: Repo.delete(challenge)

  def change_challenge(%Challenge{} = challenge, attrs \\ %{}), do: Challenge.changeset(challenge, attrs)

  def create_challenge(attrs) do
    %Challenge{} |> Challenge.changeset(attrs) |> Repo.insert()
  end

  def update_challenge(%Challenge{} = challenge, attrs) do
    locked(challenge.id, fn locked ->
      changeset = Challenge.changeset(locked, attrs)

      last_deposit = Repo.one(from c in Contribution, where: c.challenge_id == ^locked.id, select: max(c.week)) || 0

      # A shorter plan must not orphan deposits that would no longer fall inside it.
      changeset =
        if last_deposit > Ecto.Changeset.get_field(changeset, :periods) do
          Ecto.Changeset.add_error(changeset, :plan, "ends before your deposit on period #{last_deposit}. Remove those deposits first.")
        else
          changeset
        end

      Repo.update(changeset)
    end)
  end

  ## Shopping list

  @max_items 30

  @doc "Only 52-week style and goal-and-deadline goals can hold a shopping list."
  def items_supported?(%Challenge{kind: kind}), do: kind in ["weekly", "deadline"]

  def list_items(%Challenge{id: id}), do: Repo.all(from i in GoalItem, where: i.challenge_id == ^id, order_by: [asc: i.position, asc: i.id])

  def change_item(%GoalItem{} = item, attrs \\ %{}), do: GoalItem.changeset(item, attrs)

  @doc """
  Adds an item and makes the goal the total of all items, refitting the plan so
  the weekly (or per-period) amounts reach it.
  """
  def add_item(%Challenge{} = challenge, attrs) do
    locked(challenge.id, fn locked ->
      cond do
        not items_supported?(locked) ->
          {:error, GoalItem.changeset(%GoalItem{}, attrs) |> Ecto.Changeset.add_error(:name, "can't be added to this kind of goal")}

        Repo.aggregate(from(i in GoalItem, where: i.challenge_id == ^locked.id), :count) >= @max_items ->
          {:error, GoalItem.changeset(%GoalItem{}, attrs) |> Ecto.Changeset.add_error(:name, "list is full (#{@max_items} items)")}

        true ->
          position = (Repo.one(from i in GoalItem, where: i.challenge_id == ^locked.id, select: max(i.position)) || 0) + 1

          with {:ok, item} <- %GoalItem{challenge_id: locked.id, position: position} |> GoalItem.changeset(attrs) |> Repo.insert(),
               {:ok, _} <- sync_goal(locked) do
            {:ok, item}
          end
      end
    end)
  end

  def remove_item(%Challenge{id: id}, item_id) do
    locked(id, fn locked ->
      case Repo.get_by(GoalItem, id: item_id, challenge_id: id) do
        nil -> {:ok, nil}
        item -> with {:ok, _} <- Repo.delete(item), {:ok, _} <- sync_goal(locked), do: {:ok, item}
      end
    end)
  end

  @doc "Ticks an item as bought (today) or unticks it. The goal total is unchanged."
  def toggle_bought(%Challenge{id: id}, item_id, today) do
    locked(id, fn _locked ->
      case Repo.get_by(GoalItem, id: item_id, challenge_id: id) do
        nil -> {:ok, nil}
        item -> item |> Ecto.Changeset.change(bought_on: if(item.bought_on, do: nil, else: today)) |> Repo.update()
      end
    end)
  end

  # Goal = sum of item costs. A 52-week plan gets amounts that reach it; a
  # goal-and-deadline plan keeps its dates and recomputes the amount per period.
  # With no items left the goal is left as it was.
  defp sync_goal(%Challenge{} = c) do
    total = Repo.one(from i in GoalItem, where: i.challenge_id == ^c.id, select: coalesce(sum(i.cost), 0)) || 0

    attrs =
      case {c.kind, c.mode} do
        _ when total <= 0 -> nil
        {"weekly", "fixed"} -> %{plan: "weekly_fixed", target_amount: total, start_amount: div(total + Plan.weeks() - 1, Plan.weeks())}
        {"weekly", _} -> %{plan: "weekly_increasing", target_amount: total, start_amount: fit_rising(total), increment: fit_rising(total)}
        {"deadline", _} -> %{plan: "deadline", target_amount: total, frequency: c.unit, end_date: c.end_date}
      end

    if attrs, do: c |> Challenge.changeset(attrs) |> keep_past_targets(c) |> Repo.update(), else: {:ok, c}
  end

  # Once deposits exist the per-period amounts are history: changing them would
  # turn weeks you completed into missed ones. Only the goal moves, and the
  # periods still ahead share the difference (see `Plan.adaptive?/1`).
  defp keep_past_targets(changeset, %Challenge{id: id}) do
    if Repo.exists?(from c in Contribution, where: c.challenge_id == ^id) do
      changeset |> Ecto.Changeset.delete_change(:start_amount) |> Ecto.Changeset.delete_change(:increment)
    else
      changeset
    end
  end

  defp fit_rising(total) do
    sum = div(Plan.weeks() * (Plan.weeks() + 1), 2)
    div(total + sum - 1, sum)
  end

  ## Withdrawals

  @withdraw_types %{amount: :integer, reason: :string, withdrawn_on: :date}

  @doc "Form changeset for taking money out of a goal: how much, why, and when."
  def change_withdrawal(attrs \\ %{}) do
    {%{}, @withdraw_types}
    |> Ecto.Changeset.cast(attrs, Map.keys(@withdraw_types))
    |> Ecto.Changeset.update_change(:reason, &String.trim/1)
    |> Ecto.Changeset.validate_required([:amount, :reason, :withdrawn_on], message: "is needed")
    |> Ecto.Changeset.validate_length(:reason, max: 120)
    |> Ecto.Changeset.validate_number(:amount, greater_than: 0, less_than_or_equal_to: 100_000_000)
    |> Ecto.Changeset.validate_change(:withdrawn_on, fn _, date ->
      if Date.compare(date, SavingsChallenge.Clock.today()) == :gt, do: [withdrawn_on: "can't be in the future"], else: []
    end)
  end

  @doc """
  Takes money out of a goal and records why. Stored as a negative amount on the
  goal, so the saved total goes down and the entry shows in its history. Cannot
  take out more than the goal holds.
  """
  def withdraw(%Challenge{id: id}, attrs) do
    changeset = change_withdrawal(attrs)

    if changeset.valid? do
      %{amount: amount, reason: reason, withdrawn_on: date} = Ecto.Changeset.apply_changes(changeset)

      locked(id, fn goal ->
        balance = Repo.one(from c in Contribution, where: c.challenge_id == ^goal.id and c.cycle == ^goal.cycle, select: coalesce(sum(c.amount), 0)) || 0

        if amount > balance do
          {:error, changeset |> Ecto.Changeset.add_error(:amount, "is more than the KSh #{balance} saved") |> Map.put(:action, :validate)}
        else
          Repo.insert(%Contribution{challenge_id: goal.id, cycle: goal.cycle, week: 1, amount: -amount, deposited_on: date, note: reason})
        end
      end)
    else
      {:error, Map.put(changeset, :action, :validate)}
    end
  end

  @doc "Undo a withdrawal you entered by hand (debt payments are undone from the debt)."
  def undo_withdrawal(%Challenge{id: id}, contribution_id) do
    locked(id, fn _ ->
      case Repo.get_by(Contribution, id: contribution_id, challenge_id: id) do
        %Contribution{amount: a, debt_id: nil} = c when a < 0 -> Repo.delete(c)
        _ -> {:ok, nil}
      end
    end)
  end

  @doc """
  Every money movement across all goals, newest first: `%{contribution, goal_name}`.
  Pass `:withdrawals` to only get money taken out. Earlier cycles of a bill are included.
  """
  def list_movements(filter \\ :all) do
    query =
      from c in Contribution,
        join: g in Challenge,
        on: g.id == c.challenge_id,
        order_by: [desc: c.deposited_on, desc: c.id],
        select: %{contribution: c, goal_name: g.name, goal_id: g.id}

    query = if filter == :withdrawals, do: where(query, [c], c.amount < 0), else: query
    Repo.all(query)
  end

  ## Debts

  def list_debts, do: Repo.all(from d in Debt, order_by: [asc: d.id])

  def change_debt(%Debt{} = debt, attrs \\ %{}), do: Debt.changeset(debt, attrs)

  def create_debt(attrs), do: %Debt{} |> Debt.changeset(attrs) |> Repo.insert()

  @doc "Only a debt with no payments recorded can be removed."
  def delete_debt(id) do
    case Repo.get(Debt, id) do
      %Debt{paid_amount: 0} = debt -> Repo.delete(debt)
      %Debt{} -> {:error, :has_payments}
      nil -> {:ok, nil}
    end
  end

  @doc "Tranche goals that are still open: the pools money can be paid out of."
  def list_pools do
    Repo.all(from c in Challenge, where: c.kind == "tranche" and is_nil(c.completed_at), order_by: [asc: c.id])
  end

  @doc """
  Pays `amount` towards a debt. With a `pool_id` the money comes out of that
  tranche pool (its saved total goes down; it must hold enough). With `nil` it
  was paid from money kept elsewhere. The debt is marked paid once it is fully
  covered.

  Returns `{:ok, debt}` or `{:error, reason}` where reason is `:invalid_amount`,
  `:too_much`, `:no_pool` or `{:insufficient, balance}`.
  """
  def pay_debt(debt_id, amount, pool_id, today) do
    Repo.transaction(fn ->
      debt = Repo.one!(from d in Debt, where: d.id == ^debt_id, lock: "FOR UPDATE")

      cond do
        not is_integer(amount) or amount <= 0 -> Repo.rollback(:invalid_amount)
        amount > Debt.remaining(debt) -> Repo.rollback(:too_much)
        true -> :ok
      end

      if pool_id do
        pool = Repo.one(from c in Challenge, where: c.id == ^pool_id and c.kind == "tranche" and is_nil(c.completed_at), lock: "FOR UPDATE")
        if is_nil(pool), do: Repo.rollback(:no_pool)

        balance = Repo.one(from c in Contribution, where: c.challenge_id == ^pool.id and c.cycle == ^pool.cycle, select: coalesce(sum(c.amount), 0)) || 0
        if amount > balance, do: Repo.rollback({:insufficient, balance})

        Repo.insert!(%Contribution{
          challenge_id: pool.id,
          cycle: pool.cycle,
          week: 1,
          amount: -amount,
          deposited_on: today,
          note: "Paid " <> debt.name,
          debt_id: debt.id
        })
      end

      paid = debt.paid_amount + amount
      changes = %{paid_amount: paid, paid_on: if(paid >= debt.amount, do: today)}
      debt |> Ecto.Changeset.change(changes) |> Repo.update!()
    end)
  end

  @doc "Reverses every payment on a debt: money paid out of pools goes back in."
  def undo_debt(debt_id) do
    Repo.transaction(fn ->
      debt = Repo.one!(from d in Debt, where: d.id == ^debt_id, lock: "FOR UPDATE")
      Repo.delete_all(from c in Contribution, where: c.debt_id == ^debt.id)
      debt |> Ecto.Changeset.change(paid_amount: 0, paid_on: nil) |> Repo.update!()
    end)
  end

  ## Contributions

  @doc "Deposits of the goal's current cycle (a goal that is not a bill only ever has cycle 1)."
  def list_contributions(%Challenge{id: id, cycle: cycle}) do
    Repo.all(
      from c in Contribution,
        where: c.challenge_id == ^id and c.cycle == ^cycle,
        order_by: [asc: c.week, asc: c.deposited_on, asc: c.id]
    )
  end

  @doc "For goals preloaded with all contributions: keep only the current cycle."
  def current_contributions(%Challenge{contributions: all, cycle: cycle}), do: Enum.filter(all, &(&1.cycle == cycle))

  def list_bill_payments(%Challenge{id: id}) do
    Repo.all(from p in BillPayment, where: p.challenge_id == ^id, order_by: [desc: p.cycle])
  end

  @doc """
  Marks the current bill cycle as paid and records it. A one-off bill is then
  complete; a repeating one moves to its next due date with a fresh target and
  a fresh target. Anything saved beyond the bill's cost is carried into the new
  cycle as its first deposit; the old deposits stay in the history of that cycle.
  """
  def mark_bill_paid(%Challenge{kind: "bill"} = challenge, today) do
    locked(challenge.id, fn locked ->
      saved = Repo.one(from c in Contribution, where: c.challenge_id == ^locked.id and c.cycle == ^locked.cycle, select: coalesce(sum(c.amount), 0)) || 0

      Repo.insert!(%BillPayment{
        challenge_id: locked.id,
        cycle: locked.cycle,
        due_date: locked.end_date,
        amount_due: locked.target_amount,
        saved: saved,
        paid_on: today
      })

      if locked.recurrence == "once" do
        locked |> Ecto.Changeset.change(completed_at: DateTime.utc_now() |> DateTime.truncate(:second)) |> Repo.update()
      else
        due = next_future_due(locked.end_date, locked.recurrence, today)
        periods = max(Plan.periods_between(locked.unit, today, due), 1)

        locked
        |> Ecto.Changeset.change(
          cycle: locked.cycle + 1,
          start_date: today,
          end_date: due,
          periods: periods,
          start_amount: div(locked.target_amount + periods - 1, periods)
        )
        |> Repo.update()
        |> carry_surplus(locked, saved, today)
      end
    end)
  end

  # Money saved beyond what the bill cost starts the next cycle as a deposit.
  defp carry_surplus({:ok, next}, old, saved, today) do
    surplus = saved - (old.target_amount || 0)

    if surplus > 0 do
      Repo.insert!(%Contribution{
        challenge_id: next.id,
        cycle: next.cycle,
        week: 1,
        amount: surplus,
        deposited_on: today,
        note: "Carried over from last cycle",
        idempotency_key: "carry-#{next.id}-#{next.cycle}"
      })
    end

    {:ok, next}
  end

  defp carry_surplus(error, _old, _saved, _today), do: error

  # The next due date on or after today (a bill paid very late skips missed dates).
  defp next_future_due(due, recurrence, today) do
    next = Plan.next_due(due, recurrence)
    if Date.compare(next, today) == :lt, do: next_future_due(next, recurrence, today), else: next
  end

  def change_contribution(%Contribution{} = contribution, attrs \\ %{}) do
    Contribution.changeset(contribution, attrs)
  end

  @doc """
  Records a deposit. Returns `{:ok, contribution}`, `{:ok, :duplicate}` when the
  same form submission arrives twice, or `{:error, changeset}`.
  """
  def create_contribution(%Challenge{id: id, periods: periods, cycle: cycle}, attrs) do
    result =
      locked(id, fn _challenge ->
        %Contribution{challenge_id: id, cycle: cycle} |> Contribution.changeset(attrs, periods) |> Repo.insert()
      end)

    case result do
      {:error, %Ecto.Changeset{errors: errors} = cs} ->
        if Keyword.has_key?(errors, :idempotency_key), do: {:ok, :duplicate}, else: {:error, cs}

      other ->
        other
    end
  end

  def get_contribution!(%Challenge{id: id}, contribution_id) do
    Repo.get_by!(Contribution, id: contribution_id, challenge_id: id)
  end

  def update_contribution(%Challenge{id: id, periods: periods}, contribution_id, attrs) do
    locked(id, fn _challenge ->
      Contribution
      |> Repo.get_by!(id: contribution_id, challenge_id: id)
      |> Contribution.changeset(Map.drop(attrs, [:idempotency_key, "idempotency_key"]), periods)
      |> Repo.update()
    end)
  end

  def delete_contribution(%Challenge{id: id}, contribution_id) do
    locked(id, fn _challenge ->
      case Repo.get_by(Contribution, id: contribution_id, challenge_id: id) do
        nil -> {:ok, nil}
        %Contribution{amount: amount} when amount < 0 -> {:error, :debt_payment}
        contribution -> Repo.delete(contribution)
      end
    end)
  end

  # Runs `fun` inside a transaction holding a row lock on the challenge.
  # `fun` returns {:ok, _} | {:error, _}; an error rolls the transaction back.
  defp locked(challenge_id, fun) do
    Repo.transaction(fn ->
      challenge = Repo.one!(from c in Challenge, where: c.id == ^challenge_id, lock: "FOR UPDATE")

      case fun.(challenge) do
        {:ok, value} -> value
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
    |> case do
      {:ok, value} -> {:ok, value}
      {:error, reason} -> {:error, reason}
    end
  end
end
