defmodule SavingsChallengeWeb.DashboardLiveTest do
  use SavingsChallengeWeb.ConnCase

  alias SavingsChallenge.Savings

  test "visiting / with no goals sends you to create one", %{conn: conn} do
    assert {:error, {:live_redirect, %{to: "/goals/new"}}} = live(conn, "/")
  end

  test "new goal starts with a grouped category picker", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/goals/new")
    assert html =~ "What are you saving for?"

    for text <- ["Featured", "Home", "Shopping", "Personal", "Fun", "Emergency", "Furniture", "Trip or vacation", "Clear debt"] do
      assert html =~ text
    end

    assert html =~ ~s(href="/goals/new?category=trip")
    refute html =~ "settings-form"
  end

  test "picker offers the challenge types", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/goals/new")
    for text <- ["Challenges", "52-week challenge", "100 days (Mia kwa Mia)", "12 weekly envelopes", "Goal and deadline"], do: assert(html =~ text)
    assert html =~ ~s(href="/goals/new?plan=daily")
  end

  test "daily challenge: 100 days, form shows a daily amount", %{conn: conn} do
    {:ok, view, html} = live(conn, "/goals/new?plan=daily")
    assert html =~ "Daily amount (KSh)"
    assert html =~ ~s(value="100 Days Challenge")
    assert html =~ "KSh 10,000"

    view |> form("#settings-form", challenge: %{start_amount: 200}) |> render_submit()
    {path, _} = assert_redirect(view)
    {:ok, _view, html} = live(conn, path)
    assert html =~ "Day 1 of 100"
    assert html =~ "Your 100 days"
    assert html =~ "KSh 20,000 goal"
  end

  test "envelope challenge hides upcoming amounts", %{conn: conn} do
    {:ok, view, _} = live(conn, "/goals/new?plan=envelope")
    view |> form("#settings-form", challenge: %{start_amount: 100}) |> render_submit()
    {path, _} = assert_redirect(view)
    {:ok, view, html} = live(conn, path)
    assert html =~ "Your 12 weeks"
    assert html =~ "KSh 7,800 goal"
    assert html =~ ~s(<span class="cell-amt">?</span>)

    html = view |> element(~s(button.cell[phx-value-week="5"])) |> render_click()
    assert html =~ "A surprise"
    assert html =~ "revealed when it starts"
    refute html =~ "phx-click=\"pay_week\""
  end

  test "deadline goal works out the deposit amount", %{conn: conn} do
    {:ok, view, html} = live(conn, "/goals/new?plan=deadline")
    assert html =~ "When do you want to reach it?"
    end_date = Date.to_iso8601(Date.add(SavingsChallenge.Clock.today(), 9))

    html =
      view
      |> form("#settings-form", challenge: %{target_amount: 5000, end_date: end_date, frequency: "day"})
      |> render_change()

    assert html =~ "Save"
    assert html =~ "KSh 500"
    assert html =~ "10 days"
  end

  test "an unknown category falls back to the picker", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/goals/new?category=yacht")
    assert html =~ "What are you saving for?"
  end

  test "choosing a category pre-fills the form; goal amount suggests weekly amounts", %{conn: conn} do
    {:ok, view, html} = live(conn, "/goals/new?category=trip")
    assert html =~ "Create your goal"
    assert html =~ ~s(value="Trip or vacation")
    assert html =~ "Change category"

    # Typing a goal amount fills in weekly amounts that reach it: 137800 / 1378 = 100.
    html =
      view
      |> form("#settings-form", challenge: %{plan: "weekly_increasing", target_amount: 137_800})
      |> render_change(%{"_target" => ["challenge", "target_amount"]})

    assert html =~ ~s(value="100")
    assert html =~ "KSh 137,800"

    view
    |> form("#settings-form", challenge: %{name: "Zanzibar trip", category: "trip"})
    |> render_submit()

    {path, _flash} = assert_redirect(view)
    assert path =~ ~r"^/goals/\d+$"

    {:ok, _view, html} = live(conn, path)
    assert html =~ "Zanzibar trip"
    assert html =~ "Trip"
    assert html =~ "KSh 137,800 goal"
  end

  test "home lists every goal with its own progress", %{conn: conn} do
    a = challenge_fixture(%{"name" => "Laptop", "category" => "equipment"})
    challenge_fixture(%{"name" => "Zanzibar trip", "category" => "trip"})

    {:ok, _} =
      Savings.create_contribution(a, %{"week" => 1, "amount" => 50, "deposited_on" => Date.to_iso8601(SavingsChallenge.Clock.today())})

    {:ok, _view, html} = live(conn, "/")
    assert html =~ "Laptop"
    assert html =~ "Zanzibar trip"
    assert html =~ "Equipment"
    assert html =~ "2 goals"
    assert html =~ "KSh 50"
  end

  test "records, edits and deletes a deposit", %{conn: conn} do
    challenge = challenge_fixture()
    {:ok, view, html} = live(conn, "/goals/#{challenge.id}")
    assert html =~ "Week 1 of 52"

    html = view |> form("#deposit-form", deposit: %{amount: 30}) |> render_submit()
    assert html =~ "KSh 30"

    id = hd(Savings.list_contributions(challenge)).id
    view |> element(~s(button[phx-click="edit_deposit"][phx-value-id="#{id}"])) |> render_click()
    html = view |> form("#deposit-form", deposit: %{amount: 50}) |> render_submit()
    assert html =~ "Done"

    html = view |> element(~s(button[phx-click="delete_deposit"][phx-value-id="#{id}"])) |> render_click()
    assert html =~ "No deposits for this week yet."
  end

  test "shows validation errors", %{conn: conn} do
    challenge = challenge_fixture()
    {:ok, view, _} = live(conn, "/goals/#{challenge.id}")
    html = view |> form("#deposit-form", deposit: %{amount: 0}) |> render_change()
    assert html =~ "must be greater than 0"
  end

  test "deleting a goal needs a second tap and returns home", %{conn: conn} do
    keep = challenge_fixture(%{"name" => "Keep me"})
    gone = challenge_fixture(%{"name" => "Delete me"})
    {:ok, view, _} = live(conn, "/goals/#{gone.id}")

    view |> element(~s(button[phx-click="open_settings"])) |> render_click()
    html = view |> element(~s(button[phx-click="ask_delete_goal"])) |> render_click()
    assert html =~ "Yes, delete this goal"
    assert Savings.get_challenge(gone.id)

    view |> element(~s(button[phx-click="delete_goal"])) |> render_click()
    assert_redirect(view, "/")
    assert Savings.get_challenge(gone.id) == nil
    assert Savings.get_challenge(keep.id)
  end

  test "an unknown goal id goes back home", %{conn: conn} do
    challenge_fixture()
    assert {:error, {:live_redirect, %{to: "/"}}} = live(conn, "/goals/999999")
    assert {:error, {:live_redirect, %{to: "/"}}} = live(conn, "/goals/not-a-number")
  end

  describe "finishing goals, streaks, badges, notes" do
    defp pay(challenge, week, amount) do
      Savings.create_contribution(challenge, %{"week" => week, "amount" => amount, "deposited_on" => Date.to_iso8601(SavingsChallenge.Clock.today())})
    end

    test "completing a goal moves it to the Completed section; it can be reopened", %{conn: conn} do
      goal = challenge_fixture(%{"name" => "Phone", "target_amount" => 50})
      other = challenge_fixture(%{"name" => "Still going"})

      {:ok, view, html} = live(conn, "/goals/#{goal.id}")
      refute html =~ "Mark as complete"

      html = view |> form("#deposit-form", deposit: %{amount: 50}) |> render_submit()
      assert html =~ "Goal reached"
      assert html =~ "Mark as complete"

      html = view |> element(~s(button[phx-click="complete_goal"])) |> render_click()
      assert html =~ "Goal completed"
      assert html =~ "Reopen goal"
      assert Savings.get_challenge(goal.id).completed_at

      {:ok, _view, home} = live(conn, "/")
      assert home =~ "Completed"
      assert home =~ "Phone"
      assert home =~ "Still going"
      assert [_, after_completed] = String.split(home, "Completed", parts: 2)
      assert after_completed =~ "Phone"
      refute after_completed =~ "Still going"

      {:ok, view, _} = live(conn, "/goals/#{goal.id}")
      html = view |> element(~s(button[phx-click="reopen_goal"])) |> render_click()
      assert html =~ "Mark as complete"
      assert Savings.get_challenge(goal.id).completed_at == nil
      assert other.id != goal.id
    end

    test "you cannot complete a goal that is not reached", %{conn: conn} do
      goal = challenge_fixture()
      {:ok, view, _} = live(conn, "/goals/#{goal.id}")
      render_hook(view, "complete_goal", %{})
      assert Savings.get_challenge(goal.id).completed_at == nil
    end

    test "badge unlock message after the first deposit and badges card", %{conn: conn} do
      goal = challenge_fixture()
      {:ok, view, html} = live(conn, "/goals/#{goal.id}")
      assert html =~ "0 of 8 earned"

      html = view |> form("#deposit-form", deposit: %{amount: 50}) |> render_submit()
      assert html =~ "Badge unlocked"
      assert html =~ "First deposit"
      assert html =~ "1 of 8 earned" or html =~ "2 of 8 earned"
    end

    test "streak shows once periods are completed in a row", %{conn: conn} do
      goal = challenge_fixture(%{"plan" => "daily", "start_amount" => 100, "start_date" => Date.to_iso8601(Date.add(SavingsChallenge.Clock.today(), -3))})
      for day <- 1..3, do: pay(goal, day, 100)
      {:ok, _view, html} = live(conn, "/goals/#{goal.id}")
      assert html =~ "3-day streak"
      {:ok, _view, home} = live(conn, "/")
      assert home =~ "3-day streak"
    end

    test "where the money is kept shows on the goal and on home", %{conn: conn} do
      goal = challenge_fixture(%{"kept_in" => "M-Shwari savings pot"})
      {:ok, view, html} = live(conn, "/goals/#{goal.id}")
      assert html =~ "Kept in M-Shwari savings pot"

      view |> element(~s(button[phx-click="open_settings"])) |> render_click()
      html = view |> form("#settings-form", challenge: %{kept_in: "Sacco and a tin"}) |> render_submit()
      assert html =~ "Kept in Sacco and a tin"

      {:ok, _view, home} = live(conn, "/")
      assert home =~ "Sacco and a tin"
    end
  end

  describe "bills in the UI" do
    defp make_bill(name, days, extra \\ %{}) do
      today = SavingsChallenge.Clock.today()

      challenge_fixture(
        Map.merge(
          %{
            "plan" => "bill", "name" => name, "category" => "bills", "target_amount" => 3000, "frequency" => "day",
            "recurrence" => "monthly", "end_date" => Date.to_iso8601(Date.add(today, days))
          },
          extra
        )
      )
    end

    test "picker offers a bill tile and the form asks for amount, due date and repeat", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/goals/new")
      assert html =~ "Bill or subscription"
      assert html =~ ~s(href="/goals/new?plan=bill")

      {:ok, view, html} = live(conn, "/goals/new?plan=bill")
      for text <- ["Amount due (KSh)", "Next due date", "Does it repeat?", "Set aside"], do: assert(html =~ text)
      assert html =~ ~s(<option value="day" selected)

      due = Date.to_iso8601(Date.add(SavingsChallenge.Clock.today(), 29))
      html = view |> form("#settings-form", challenge: %{target_amount: 3000, end_date: due, frequency: "day"}) |> render_change()
      assert html =~ "Set aside"
      assert html =~ "KSh 100"
      assert html =~ "30 days"
    end

    test "bill dashboard shows the due date and daily set-aside", %{conn: conn} do
      bill = make_bill("Electricity", 9)
      {:ok, _view, html} = live(conn, "/goals/#{bill.id}")
      assert html =~ "Due in 9 days"
      assert html =~ "repeats every month"
      assert html =~ "Mark as paid"
      assert html =~ "Next: <strong>KSh 300</strong>"
      refute html =~ "Mark as complete"
    end

    test "mark as paid needs a second tap, then rolls to the next cycle with history", %{conn: conn} do
      bill = make_bill("Rent", 5, %{"target_amount" => 600})
      {:ok, view, _} = live(conn, "/goals/#{bill.id}")
      view |> form("#deposit-form", deposit: %{amount: 100}) |> render_submit()

      html = view |> element(~s(button[phx-click="ask_paid"])) |> render_click()
      assert html =~ "Confirm: I paid it"
      assert Savings.get_challenge(bill.id).cycle == 1

      html = view |> element(~s(button[phx-click="mark_paid"])) |> render_click()
      assert html =~ "Payment history"
      assert html =~ "you had set aside KSh 100"
      assert html =~ "Paid."
      assert Savings.get_challenge(bill.id).cycle == 2
      assert html =~ "KSh 0"
    end

    test "a one-off bill shows 'Bill paid' afterwards", %{conn: conn} do
      bill = make_bill("Car service", 3, %{"recurrence" => "once"})
      {:ok, view, _} = live(conn, "/goals/#{bill.id}")
      view |> element(~s(button[phx-click="ask_paid"])) |> render_click()
      html = view |> element(~s(button[phx-click="mark_paid"])) |> render_click()
      assert html =~ "Bill paid"
      refute html =~ "Mark as paid"
    end

    test "home puts bills first, soonest due date first", %{conn: conn} do
      challenge_fixture(%{"name" => "Plain goal"})
      make_bill("Later bill", 20)
      make_bill("Sooner bill", 2)

      {:ok, _view, html} = live(conn, "/")
      assert html =~ "Due in 2 days"
      positions = for n <- ["Sooner bill", "Later bill", "Plain goal"], do: elem(:binary.match(html, n), 0)
      assert positions == Enum.sort(positions)
    end
  end

  test "shopping list: add items, goal becomes the total, mark bought", %{conn: conn} do
    {:ok, c} = Savings.create_challenge(%{"name" => "Home", "category" => "furniture", "plan" => "weekly_fixed", "start_amount" => "100", "start_date" => Date.to_iso8601(SavingsChallenge.Clock.today())})
    {:ok, view, html} = live(conn, "/goals/#{c.id}")
    assert html =~ "Shopping list"

    html = view |> form("#add-item-form", item: %{name: "TV", cost: "26000"}) |> render_submit()
    assert html =~ "TV"
    assert html =~ "26,000"

    html = view |> form("#add-item-form", item: %{name: "Fridge", cost: "26000"}) |> render_submit()
    assert html =~ "Fridge"
    assert html =~ "52,000"
    assert html =~ "Waiting"

    # Save the first item's price in full: it becomes ready to buy.
    {:ok, _} = Savings.create_contribution(Savings.get_challenge(c.id), %{"week" => 1, "amount" => "26000", "deposited_on" => Date.to_iso8601(SavingsChallenge.Clock.today())})
    {:ok, view, html} = live(conn, "/goals/#{c.id}")
    assert html =~ "Ready to buy"

    html = view |> element("button", "Bought") |> render_click()
    assert html =~ "Bought "
  end

  test "tranche goal: create, then deposit any amount into the pool", %{conn: conn} do
    {:ok, view, html} = live(conn, "/goals/new?plan=tranche")
    assert html =~ "How much do you want to save?"
    refute html =~ "Weekly amount"

    html = render_change(view, "validate_settings", %{"challenge" => %{"name" => "Car", "plan" => "tranche", "target_amount" => "2500000", "start_date" => Date.to_iso8601(SavingsChallenge.Clock.today()), "category" => "general"}})
    assert html =~ "52 tranches of about"

    view |> form("#settings-form") |> render_submit()
    [c] = Savings.list_challenges()
    assert c.kind == "tranche"

    {:ok, view, html} = live(conn, "/goals/#{c.id}")
    assert html =~ "Filling tranche 1"
    assert html =~ "Tranche 1 of 52"

    html = view |> form("#deposit-form", deposit: %{amount: "100000"}) |> render_submit()
    assert html =~ "Filling tranche 3"
    assert Enum.map(Savings.list_contributions(c), & &1.week) == [1]
  end

  test "home screen: balance card with hide toggle, goal cards and tab bar", %{conn: conn} do
    today = Date.to_iso8601(SavingsChallenge.Clock.today())
    {:ok, c} = Savings.create_challenge(%{"name" => "Car", "category" => "general", "plan" => "weekly_fixed", "start_amount" => "1000", "start_date" => today})
    {:ok, _} = Savings.create_contribution(c, %{"week" => 1, "amount" => "400", "deposited_on" => today})

    {:ok, _view, html} = live(conn, "/")
    assert html =~ ~s(phx-hook="Eye")
    assert html =~ "Total saved" and html =~ "KSh 400"
    assert html =~ "Today&#39;s target" or html =~ "Today's target"
    assert html =~ "KSh 600"
    assert html =~ "amt-mask"
    assert html =~ "Your goals" and html =~ "Car"
    assert html =~ "weeks to go"
    assert html =~ ~s(class="tabbar")
    assert html =~ ~s(href="/goals/#{c.id}#deposit-form")
  end

  test "goal detail shows monthly analytics, transactions and a top up button", %{conn: conn} do
    today = Date.to_iso8601(SavingsChallenge.Clock.today())
    {:ok, c} = Savings.create_challenge(%{"name" => "Car", "category" => "general", "plan" => "weekly_fixed", "start_amount" => "1000", "start_date" => today})
    {:ok, _} = Savings.create_contribution(c, %{"week" => 1, "amount" => "400", "note" => "Bonus", "deposited_on" => today})

    {:ok, _view, html} = live(conn, "/goals/#{c.id}")
    assert html =~ "Saving analytics"
    assert html =~ "Average per month"
    assert html =~ "Transactions" and html =~ "Bonus" and html =~ "+KSh 400"
    assert html =~ ~s(href="#deposit-form")
  end

  test "home shows when a future goal starts and counts nothing for it today", %{conn: conn} do
    start = SavingsChallenge.Clock.today() |> Date.add(7)
    {:ok, _} = Savings.create_challenge(%{"name" => "December", "category" => "event", "plan" => "deadline", "target_amount" => "80000", "frequency" => "week", "start_date" => Date.to_iso8601(start), "end_date" => Date.to_iso8601(Date.add(start, 50))})
    {:ok, _view, html} = live(conn, "/")
    assert html =~ "Starts in 7 days"
    assert html =~ ~s(<span class="amt">KSh 0</span>)
  end

  test "debts card: add, pay from the pool, owed total goes down", %{conn: conn} do
    today = Date.to_iso8601(SavingsChallenge.Clock.today())
    {:ok, pool} = Savings.create_challenge(%{"name" => "Pool", "category" => "general", "plan" => "tranche", "target_amount" => "520000", "start_date" => today})
    {:ok, _} = Savings.create_contribution(pool, %{"week" => 1, "amount" => "30000", "deposited_on" => today})

    {:ok, view, html} = live(conn, "/")
    assert html =~ "Debts" and html =~ "Nobody to pay"

    view |> form("#add-debt-form", debt: %{name: "John", amount: "12000"}) |> render_submit()
    html = view |> form("#add-debt-form", debt: %{name: "Mary", amount: "5000"}) |> render_submit()
    assert html =~ "KSh 17,000</strong> owed"

    [john, _mary] = Savings.list_debts()
    view |> element(~s(button[phx-click="ask_pay"][phx-value-id="#{john.id}"])) |> render_click()
    assert render(view) =~ "Pool · KSh 30,000 saved"

    html = view |> form(".pay-form", %{"amount" => "12000", "pool" => "#{pool.id}"}) |> render_submit()
    assert html =~ "John paid"
    assert html =~ "KSh 5,000</strong> owed"
    # John sits under Paid, below Mary (still unpaid)
    [_, card] = String.split(html, ~s(id="debts"), parts: 2)
    [above, below] = String.split(card, "Paid</h3>", parts: 2)
    assert above =~ "Mary" and not (above =~ "John")
    assert below =~ "John"
    # The pool went down.
    assert html =~ "KSh 18,000"
  end

  test "the pool's page lists the payment as money out and gives no edit for it", %{conn: conn} do
    today = Date.to_iso8601(SavingsChallenge.Clock.today())
    {:ok, pool} = Savings.create_challenge(%{"name" => "Pool", "category" => "general", "plan" => "tranche", "target_amount" => "520000", "start_date" => today})
    {:ok, _} = Savings.create_contribution(pool, %{"week" => 1, "amount" => "30000", "deposited_on" => today})
    {:ok, john} = Savings.create_debt(%{"name" => "John", "amount" => "12000"})
    {:ok, _} = Savings.pay_debt(john.id, 12_000, pool.id, SavingsChallenge.Clock.today())

    {:ok, _view, html} = live(conn, "/goals/#{pool.id}")
    assert html =~ "Paid John"
    assert html =~ "-KSh 12,000"
  end

  test "withdraw from a goal with a reason, see it in the goal and in History", %{conn: conn} do
    today = Date.to_iso8601(SavingsChallenge.Clock.today())
    {:ok, c} = Savings.create_challenge(%{"name" => "Car", "category" => "general", "plan" => "weekly_fixed", "start_amount" => "1000", "target_amount" => "52000", "start_date" => today})
    {:ok, _} = Savings.create_contribution(c, %{"week" => 1, "amount" => "5000", "deposited_on" => today})

    {:ok, view, html} = live(conn, "/goals/#{c.id}")
    assert html =~ "Take money out" and html =~ "Why are you taking it out?"

    # Too much is refused with a message and nothing changes.
    html = view |> form("#withdraw-form", withdraw: %{amount: "9000", reason: "Too much", withdrawn_on: today}) |> render_submit()
    assert html =~ "is more than the KSh 5000 saved"

    html = view |> form("#withdraw-form", withdraw: %{amount: "1200", reason: "School fees", withdrawn_on: today}) |> render_submit()
    assert html =~ "Withdrawal recorded"
    assert html =~ "School fees" and html =~ "-KSh 1,200"
    assert html =~ "Taken out KSh 1,200"

    {:ok, _view, hist} = live(conn, "/history?show=withdrawals")
    assert hist =~ "School fees" and hist =~ "Car" and hist =~ "-KSh 1,200"

    {:ok, _view, all} = live(conn, "/history")
    assert all =~ "Put in" and all =~ "+KSh 5,000"

    {:ok, home, home_html} = live(conn, "/")
    assert home_html =~ ~s(href="/history")
    _ = home
  end

  test "a withdrawal entered by hand can be undone from the goal page", %{conn: conn} do
    today = Date.to_iso8601(SavingsChallenge.Clock.today())
    {:ok, c} = Savings.create_challenge(%{"name" => "Car", "category" => "general", "plan" => "weekly_fixed", "start_amount" => "1000", "target_amount" => "52000", "start_date" => today})
    {:ok, _} = Savings.create_contribution(c, %{"week" => 1, "amount" => "5000", "deposited_on" => today})
    {:ok, _} = Savings.withdraw(c, %{"amount" => "1000", "reason" => "Oops", "withdrawn_on" => today})

    {:ok, view, _} = live(conn, "/goals/#{c.id}")
    html = view |> element("#withdrawals button", "Undo") |> render_click()
    assert html =~ "Withdrawal undone"
    assert html =~ "Nothing taken out yet"
  end
end
