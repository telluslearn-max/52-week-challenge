{:ok, _} = SavingsChallenge.Mailer.Inbox.start_link([])
ExUnit.start()
Ecto.Adapters.SQL.Sandbox.mode(SavingsChallenge.Repo, :manual)
