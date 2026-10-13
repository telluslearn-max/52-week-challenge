defmodule SavingsChallengeWeb.ConnCase do
  use ExUnit.CaseTemplate

  using do
    quote do
      @endpoint SavingsChallengeWeb.Endpoint
      import Plug.Conn
      import Phoenix.ConnTest
      import Phoenix.LiveViewTest
      import SavingsChallenge.DataCase, only: [challenge_fixture: 0, challenge_fixture: 1]
    end
  end

  setup tags do
    pid = Ecto.Adapters.SQL.Sandbox.start_owner!(SavingsChallenge.Repo, shared: not tags[:async])
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(pid) end)
    {:ok, conn: Phoenix.ConnTest.build_conn()}
  end
end
