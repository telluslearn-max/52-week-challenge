defmodule SavingsChallenge.Savings do
  @moduledoc """
  Context for the challenge and its contributions.

  Every write runs in a transaction that first locks the challenge row, so
  concurrent writes for the same challenge are serialised. Totals are never
  stored: they are computed from the contributions (see `Plan.snapshot/3`),
  which is what keeps them accurate after edits and deletes.
  """
  import Ecto.Query

  alias SavingsChallenge.{Challenge, Contribution, Repo}

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

  def count_challenges, do: Repo.aggregate(Challenge, :count)

  @doc "Deletes a goal; its contributions are removed by the database (on_delete: :delete_all)."
  def delete_challenge(%Challenge{} = challenge), do: Repo.delete(challenge)

  def change_challenge(%Challenge{} = challenge, attrs \\ %{}), do: Challenge.changeset(challenge, attrs)

  def create_challenge(attrs) do
    %Challenge{} |> Challenge.changeset(attrs) |> Repo.insert()
  end

  def update_challenge(%Challenge{} = challenge, attrs) do
    locked(challenge.id, fn locked ->
      locked |> Challenge.changeset(attrs) |> Repo.update()
    end)
  end

  ## Contributions

  def list_contributions(%Challenge{id: id}) do
    Repo.all(from c in Contribution, where: c.challenge_id == ^id, order_by: [asc: c.week, asc: c.deposited_on, asc: c.id])
  end

  def change_contribution(%Contribution{} = contribution, attrs \\ %{}) do
    Contribution.changeset(contribution, attrs)
  end

  @doc """
  Records a deposit. Returns `{:ok, contribution}`, `{:ok, :duplicate}` when the
  same form submission arrives twice, or `{:error, changeset}`.
  """
  def create_contribution(%Challenge{id: id}, attrs) do
    result =
      locked(id, fn _challenge ->
        %Contribution{challenge_id: id} |> Contribution.changeset(attrs) |> Repo.insert()
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

  def update_contribution(%Challenge{id: id}, contribution_id, attrs) do
    locked(id, fn _challenge ->
      Contribution
      |> Repo.get_by!(id: contribution_id, challenge_id: id)
      |> Contribution.changeset(Map.drop(attrs, [:idempotency_key, "idempotency_key"]))
      |> Repo.update()
    end)
  end

  def delete_contribution(%Challenge{id: id}, contribution_id) do
    locked(id, fn _challenge ->
      case Repo.get_by(Contribution, id: contribution_id, challenge_id: id) do
        nil -> {:ok, nil}
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
