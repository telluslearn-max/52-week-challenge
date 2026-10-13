defmodule SavingsChallengeWeb.LockLiveTest do
  use SavingsChallengeWeb.ConnCase

  alias SavingsChallenge.{AppSettings, Lock, Repo}
  alias SavingsChallenge.Mailer.Inbox

  defp press(view, digits) do
    for d <- String.graphemes(digits), do: view |> element(~s(button[phx-click="digit"][phx-value-d="#{d}"])) |> render_click()
  end

  defp unlock_conn(conn), do: Plug.Test.init_test_session(conn, unlocked_at: System.system_time(:second))

  setup do
    Inbox.clear()
    :ok
  end

  test "without a PIN the app is open and the lock screen goes home", %{conn: conn} do
    assert {:error, {:redirect, %{to: "/"}}} = live(conn, "/unlock")
    challenge_fixture()
    {:ok, _view, html} = live(conn, "/")
    assert html =~ "Protect your savings with a PIN"
  end

  test "setup: email, PIN, confirm, then unlocked", %{conn: conn} do
    {:ok, view, html} = live(conn, "/unlock/setup")
    assert html =~ "Recovery email"

    html = view |> form("#email-form", email: "nope") |> render_submit()
    assert html =~ "valid email"

    html = view |> form("#email-form", email: "me@example.com") |> render_submit()
    assert html =~ "Create your PIN"
    assert html =~ "4 digits"

    press(view, "1357")
    html = render(view)
    assert html =~ "Confirm your PIN"

    press(view, "1357")
    {path, _} = assert_redirect(view)
    assert path =~ "/unlock/complete?t="

    assert Lock.pin_set?()
    assert :ok = Lock.verify_pin("1357")

    # Following the redirect unlocks the session.
    challenge_fixture()
    conn = get(conn, path)
    assert redirected_to(conn) == "/"
    assert get_session(conn, :unlocked_at)
    {:ok, _view, html} = live(recycle(conn), "/")
    assert html =~ "Total saved"
  end

  test "mismatched confirmation starts over", %{conn: conn} do
    {:ok, view, _} = live(conn, "/unlock/setup")
    view |> form("#email-form", email: "me@example.com") |> render_submit()
    press(view, "1111")
    press(view, "2222")
    html = render(view)
    assert html =~ "did not match"
    assert html =~ "Create your PIN"
    refute Lock.pin_set?()
  end

  test "six digit PIN can be chosen at setup", %{conn: conn} do
    {:ok, view, _} = live(conn, "/unlock/setup")
    view |> form("#email-form", email: "me@example.com") |> render_submit()
    view |> element(~s(button[phx-value-len="6"])) |> render_click()
    press(view, "123456")
    press(view, "123456")
    assert_redirect(view)
    assert Lock.pin_length() == 6
  end

  describe "with a PIN set" do
    setup do
      :ok = Lock.set_pin("1234", "me@example.com")
      :ok
    end

    test "the app is behind the PIN, over HTTP and over the socket", %{conn: conn} do
      challenge_fixture()
      assert redirected_to(get(conn, "/")) == "/unlock"
      assert redirected_to(get(conn, "/goals/1")) == "/unlock"
      assert {:error, {:redirect, %{to: "/unlock"}}} = live(conn, "/")
      assert {:ok, _view, _html} = live(unlock_conn(conn), "/")
    end

    test "an old unlocked session expires", %{conn: conn} do
      old = Plug.Test.init_test_session(conn, unlocked_at: System.system_time(:second) - 13 * 3600)
      assert redirected_to(get(old, "/")) == "/unlock"
    end

    test "right PIN unlocks, wrong PIN counts down then locks", %{conn: conn} do
      {:ok, view, html} = live(conn, "/unlock")
      assert html =~ "Enter your PIN"

      press(view, "9999")
      assert render(view) =~ "Wrong PIN. 4 tries left."

      press(view, "9999")
      assert render(view) =~ "3 tries left"

      press(view, "1234")
      {path, _} = assert_redirect(view)
      assert path =~ "/unlock/complete"
    end

    test "five wrong tries show a lockout message", %{conn: conn} do
      {:ok, view, _} = live(conn, "/unlock")
      for _ <- 1..5, do: press(view, "0000")
      assert render(view) =~ "Too many wrong tries"
      press(view, "1234")
      assert render(view) =~ "Too many wrong tries"
    end

    test "/lock ends the session", %{conn: conn} do
      conn = conn |> unlock_conn() |> get("/lock")
      assert redirected_to(conn) == "/unlock"
    end

    test "complete rejects a bad token", %{conn: conn} do
      conn = get(conn, "/unlock/complete?t=garbage")
      assert redirected_to(conn) == "/unlock"
      refute get_session(conn, :unlocked_at)
    end

    test "forgot PIN: email link, new PIN, unlocked", %{conn: conn} do
      {:ok, view, _} = live(conn, "/unlock")
      view |> element(~s(button[phx-click="forgot"])) |> render_click()
      html = view |> element(~s(button[phx-click="send_reset"])) |> render_click()
      assert html =~ "m**@example.com"

      [%{text: text}] = Inbox.all()
      [_, token] = Regex.run(~r{/unlock/reset/([\w-]+)}, text)

      {:ok, view, html} = live(build_conn(), "/unlock/reset/#{token}")
      assert html =~ "Choose a new PIN"
      press(view, "8642")
      press(view, "8642")
      {path, _} = assert_redirect(view)
      assert path =~ "/unlock/complete"
      assert :ok = Lock.verify_pin("8642")

      # The link is single-use.
      {:ok, _view, html} = live(build_conn(), "/unlock/reset/#{token}")
      assert html =~ "invalid or has expired"
    end

    test "a bogus reset link is refused", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/unlock/reset/nonsense")
      assert html =~ "Link expired"
    end

    test "change PIN needs the session to be unlocked, then the current PIN", %{conn: conn} do
      assert {:error, {:redirect, %{to: "/unlock"}}} = live(conn, "/unlock/change")

      {:ok, view, html} = live(unlock_conn(conn), "/unlock/change")
      assert html =~ "current PIN"
      press(view, "1234")
      assert render(view) =~ "Choose a new PIN"
      press(view, "7777")
      press(view, "7777")
      assert_redirect(view)
      assert :ok = Lock.verify_pin("7777")
    end

    test "reset email goes only to the stored address and the PIN settings row is a singleton", %{conn: _conn} do
      {:ok, _} = Lock.request_reset()
      assert [%{to: "me@example.com"}] = Inbox.all()
      assert Repo.aggregate(AppSettings, :count) == 1
    end
  end
end
