{:ok, _} = SavingsChallenge.Mailer.Inbox.start_link([])
{:ok, _} = SavingsChallenge.PushStub.start_link([])

Application.put_env(:savings_challenge, :vapid, Map.put(SavingsChallenge.WebPush.generate_vapid_keys(), :subject, "mailto:test@example.com"))
Application.put_env(:savings_challenge, :push_sender, &SavingsChallenge.PushStub.deliver/3)
Application.put_env(:savings_challenge, :cron_secret, "test-secret")

ExUnit.start()
Ecto.Adapters.SQL.Sandbox.mode(SavingsChallenge.Repo, :manual)
