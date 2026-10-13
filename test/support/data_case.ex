defmodule SavingsChallenge.DataCase do
  use ExUnit.CaseTemplate

  using do
    quote do
      alias SavingsChallenge.Repo
      import Ecto.Query
      import SavingsChallenge.DataCase
    end
  end

  setup tags do
    pid = Ecto.Adapters.SQL.Sandbox.start_owner!(SavingsChallenge.Repo, shared: not tags[:async])
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(pid) end)
    :ok
  end

  def challenge_fixture(attrs \\ %{}) do
    {:ok, challenge} =
      attrs
      |> Enum.into(%{"mode" => "increasing", "start_amount" => 50, "increment" => 50, "start_date" => Date.to_iso8601(SavingsChallenge.Clock.today())})
      |> SavingsChallenge.Savings.create_challenge()

    challenge
  end
end
