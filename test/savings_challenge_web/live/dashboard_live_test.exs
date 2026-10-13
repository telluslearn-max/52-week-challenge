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
    assert html =~ "across 2 goals"
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
end
