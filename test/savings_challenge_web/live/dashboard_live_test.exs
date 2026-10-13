defmodule SavingsChallengeWeb.DashboardLiveTest do
  use SavingsChallengeWeb.ConnCase

  test "first visit shows the setup form and creates a challenge", %{conn: conn} do
    {:ok, view, html} = live(conn, "/")
    assert html =~ "Create your challenge"

    html =
      view
      |> form("#settings-form", challenge: %{start_amount: 100, increment: 100, mode: "increasing"})
      |> render_change()

    assert html =~ "KSh 137,800"

    html = view |> form("#settings-form") |> render_submit()
    assert html =~ "Total saved"
    assert html =~ "KSh 137,800 goal"
  end

  test "records, edits and deletes a deposit", %{conn: conn} do
    challenge_fixture()
    {:ok, view, html} = live(conn, "/")
    assert html =~ "Week 1 of 52"

    html = view |> form("#deposit-form", deposit: %{amount: 30}) |> render_submit()
    assert html =~ "KSh 30"
    assert html =~ "20"

    id = hd(SavingsChallenge.Savings.list_contributions(SavingsChallenge.Savings.get_challenge())).id
    view |> element(~s(button[phx-click="edit_deposit"][phx-value-id="#{id}"])) |> render_click()
    html = view |> form("#deposit-form", deposit: %{amount: 50}) |> render_submit()
    assert html =~ "Done"

    html = view |> element(~s(button[phx-click="delete_deposit"][phx-value-id="#{id}"])) |> render_click()
    assert html =~ "No deposits for this week yet."
  end

  test "shows validation errors", %{conn: conn} do
    challenge_fixture()
    {:ok, view, _} = live(conn, "/")
    html = view |> form("#deposit-form", deposit: %{amount: 0}) |> render_change()
    assert html =~ "must be greater than 0"
  end
end
