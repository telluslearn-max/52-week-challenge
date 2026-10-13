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
      |> form("#settings-form", challenge: %{mode: "increasing", target_amount: 137_800})
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
end
