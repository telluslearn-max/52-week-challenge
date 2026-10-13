defmodule SavingsChallenge.RemindersTest do
  use SavingsChallenge.DataCase

  alias SavingsChallenge.{Clock, Push, PushStub, Reminders, Savings}
  alias SavingsChallenge.WebPush

  setup do
    PushStub.clear()
    :ok
  end

  defp device(endpoint \\ "https://push.example.com/send/abc") do
    {pub, _} = :crypto.generate_key(:ecdh, :secp256r1)
    {:ok, sub} = Push.subscribe(%{endpoint: endpoint, p256dh: WebPush.b64e(pub), auth: WebPush.b64e(:crypto.strong_rand_bytes(16))})
    sub
  end

  defp at(date, hour), do: DateTime.new!(date, Time.new!(hour, 0, 0))
  defp today, do: Clock.today()

  defp daily_goal(name \\ "Daily saver", amount \\ 100) do
    challenge_fixture(%{"plan" => "daily", "name" => name, "start_amount" => amount})
  end

  defp bill(name, days) do
    challenge_fixture(%{
      "plan" => "bill", "name" => name, "target_amount" => 3000, "frequency" => "day", "recurrence" => "monthly",
      "end_date" => Date.to_iso8601(Date.add(today(), days))
    })
  end

  describe "digest" do
    test "lists what to save today and sums it" do
      daily_goal("Daily saver", 100)
      challenge_fixture(%{"name" => "Weekly", "mode" => "fixed", "start_amount" => 250})

      d = Reminders.current_digest()
      assert Enum.sort(Enum.map(d.items, & &1.name)) == ["Daily saver", "Weekly"]
      assert d.total == 350
    end

    test "skips periods already paid, reached goals and completed goals" do
      paid = daily_goal("Paid today", 100)
      {:ok, _} = Savings.create_contribution(paid, %{"week" => 1, "amount" => 100, "deposited_on" => Date.to_iso8601(today())})
      done = daily_goal("Done", 100)
      {:ok, _} = Savings.complete_challenge(done)

      d = Reminders.current_digest()
      assert d.items == []
      assert Reminders.message(d) == nil
    end

    test "bills due within 3 days are flagged, later ones are not" do
      bill("Rent", 2)
      bill("Far away", 10)
      d = Reminders.current_digest()
      assert [%{name: "Rent", days: 2}] = d.due_soon
      # Both bills also have a daily set-aside to do today.
      assert length(d.items) == 2
    end

    test "message wording" do
      daily_goal("Trip", 500)
      bill("Rent", 1)
      msg = Reminders.current_digest() |> Reminders.message()
      assert msg.title == "Time to save: KSh 2,000 today"
      assert msg.body =~ "KSh 500 · Trip"
      assert msg.body =~ "Rent is due tomorrow"
      assert msg.url == "/"
    end

    test "only a due-soon bill, nothing to save: different title" do
      msg = Reminders.message(%{items: [], total: 0, due_soon: [%{name: "Rent", days: 0}]})
      assert msg.title == "A bill is due soon"
      assert msg.body =~ "Rent is due today"
    end
  end

  describe "run_daily" do
    test "does nothing without a registered device" do
      daily_goal()
      assert {:skipped, :no_devices} = Reminders.run_daily(at(today(), 9))
      assert PushStub.all() == []
    end

    test "does nothing when push is not configured" do
      device()
      original = Application.get_env(:savings_challenge, :vapid)
      Application.delete_env(:savings_challenge, :vapid)
      on_exit(fn -> Application.put_env(:savings_challenge, :vapid, original) end)
      assert {:skipped, :push_not_configured} = Reminders.run_daily(at(today(), 9))
    end

    test "waits for the chosen hour, then sends once per day" do
      device()
      daily_goal("Trip", 300)

      assert {:skipped, :too_early} = Reminders.run_daily(at(today(), 6))
      assert PushStub.all() == []

      assert {:sent, %{sent: 1, removed: 0, failed: 0}} = Reminders.run_daily(at(today(), 9))
      assert [%{message: %{"title" => title, "body" => body}}] = PushStub.all()
      assert title =~ "KSh 300"
      assert body =~ "Trip"

      # The scheduler pings again (and again): still one reminder.
      assert {:skipped, :already_sent} = Reminders.run_daily(at(today(), 9))
      assert {:skipped, :already_sent} = Reminders.run_daily(at(today(), 18))
      assert length(PushStub.all()) == 1

      # A new day sends again.
      tomorrow = Date.add(today(), 1)
      assert {:sent, %{sent: 1}} = Reminders.run_daily(at(tomorrow, 8))
      assert length(PushStub.all()) == 2
    end

    test "respects the on/off switch and the hour setting" do
      device()
      daily_goal()

      {:ok, _} = Reminders.update_settings(%{reminders_enabled: false})
      assert {:skipped, :disabled} = Reminders.run_daily(at(today(), 12))

      {:ok, _} = Reminders.update_settings(%{reminders_enabled: true, reminder_hour: 20})
      assert {:skipped, :too_early} = Reminders.run_daily(at(today(), 12))
      assert {:sent, _} = Reminders.run_daily(at(today(), 20))
    end

    test "nothing to save: skipped, and the day is still claimed" do
      device()
      assert {:skipped, :nothing_to_save} = Reminders.run_daily(at(today(), 9))
      assert {:skipped, :already_sent} = Reminders.run_daily(at(today(), 10))
    end

    test "expired devices are removed, failing ones are counted" do
      device("https://push.example.com/ok")
      device("https://push.example.com/gone/1")
      device("https://push.example.com/broken/1")
      daily_goal()

      assert {:sent, %{sent: 1, removed: 1, failed: 1}} = Reminders.run_daily(at(today(), 9))
      assert Push.count() == 2
    end

    test "concurrent pings send only one reminder" do
      device()
      daily_goal()
      now = at(today(), 9)

      results =
        1..5
        |> Task.async_stream(fn _ -> Ecto.Adapters.SQL.Sandbox.allow(SavingsChallenge.Repo, self(), self()); Reminders.run_daily(now) end, timeout: 20_000)
        |> Enum.map(fn {:ok, r} -> r end)

      assert length(PushStub.all()) <= 1
      assert Enum.count(results, &match?({:sent, _}, &1)) <= 1
    end
  end

  describe "subscriptions" do
    defp keys do
      {pub, _} = :crypto.generate_key(:ecdh, :secp256r1)
      %{p256dh: WebPush.b64e(pub), auth: WebPush.b64e(:crypto.strong_rand_bytes(16))}
    end

    test "saves, refreshes the same endpoint, and removes" do
      attrs = Map.put(keys(), :endpoint, "https://push.example.com/a")
      assert {:ok, _} = Push.subscribe(attrs)
      assert {:ok, _} = Push.subscribe(Map.merge(attrs, keys()))
      assert Push.count() == 1
      assert Push.subscribed?("https://push.example.com/a")

      Push.unsubscribe("https://push.example.com/a")
      assert Push.count() == 0
      refute Push.subscribed?("https://push.example.com/a")
    end

    test "rejects unsafe endpoints and malformed keys" do
      k = keys()
      for bad <- ["http://push.example.com/a", "https://localhost/a", "https://127.0.0.1/a", "https://10.0.0.5/a", "ftp://x.com/a", "nonsense"] do
        assert {:error, cs} = Push.subscribe(Map.put(k, :endpoint, bad))
        assert Keyword.has_key?(cs.errors, :endpoint), bad
      end

      assert {:error, cs} = Push.subscribe(%{endpoint: "https://push.example.com/a", p256dh: "short", auth: k.auth})
      assert Keyword.has_key?(cs.errors, :p256dh)
      assert {:error, cs} = Push.subscribe(%{endpoint: "https://push.example.com/a", p256dh: k.p256dh, auth: "short"})
      assert Keyword.has_key?(cs.errors, :auth)
    end
  end
end
