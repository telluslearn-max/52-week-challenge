defmodule SavingsChallengeWeb.NotifyLiveTest do
  use SavingsChallengeWeb.ConnCase

  alias SavingsChallenge.{Push, PushStub, Reminders}

  setup do
    PushStub.clear()
    :ok
  end

  defp valid_sub(endpoint \\ "https://push.example.com/phone") do
    {pub, _} = :crypto.generate_key(:ecdh, :secp256r1)
    %{"endpoint" => endpoint, "p256dh" => Base.url_encode64(pub, padding: false), "auth" => Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false)}
  end

  test "shows the device state reported by the browser", %{conn: conn} do
    {:ok, view, html} = live(conn, "/reminders")
    assert html =~ "Checking this device"

    html = render_hook(view, "push_state", %{"supported" => true, "permission" => "default", "subscribed" => false})
    assert html =~ "Turn on notifications"
    assert html =~ ~s(data-push="enable")

    html = render_hook(view, "push_state", %{"supported" => false, "permission" => "unsupported", "subscribed" => false})
    assert html =~ "add the app to your Home Screen"

    html = render_hook(view, "push_state", %{"supported" => true, "permission" => "denied", "subscribed" => false})
    assert html =~ "Notifications are blocked"
  end

  test "subscribing saves the device; turning off removes it", %{conn: conn} do
    {:ok, view, _} = live(conn, "/reminders")
    sub = valid_sub()

    html = render_hook(view, "subscribe", sub)
    assert html =~ "Notifications are on for this device"
    assert Push.count() == 1
    assert html =~ "1 device will get reminders"

    html = render_hook(view, "unsubscribe", %{"endpoint" => sub["endpoint"]})
    assert html =~ "Notifications are off for this device"
    assert Push.count() == 0
  end

  test "a bad subscription is refused", %{conn: conn} do
    {:ok, view, _} = live(conn, "/reminders")
    html = render_hook(view, "subscribe", %{"endpoint" => "http://evil.test/x", "p256dh" => "x", "auth" => "y"})
    assert html =~ "Could not turn notifications on"
    assert Push.count() == 0
  end

  test "send a test reaches every device", %{conn: conn} do
    {:ok, view, _} = live(conn, "/reminders")

    html = render_hook(view, "send_test", %{})
    assert html =~ "Turn notifications on for a device first"

    render_hook(view, "subscribe", valid_sub())
    render_hook(view, "push_state", %{"supported" => true, "permission" => "granted", "subscribed" => true, "endpoint" => "https://push.example.com/phone"})
    html = view |> element(~s(button[phx-click="send_test"])) |> render_click()
    assert html =~ "Test sent to 1 device"
    assert [%{message: %{"title" => "Notifications are on"}}] = PushStub.all()
  end

  test "saving the hour and the on/off switch", %{conn: conn} do
    {:ok, view, _} = live(conn, "/reminders")
    view |> form("#reminder-form", reminder_hour: "19", reminders_enabled: "true") |> render_change()
    assert Reminders.settings().reminder_hour == 19

    render_hook(view, "save_settings", %{"reminders_enabled" => "false", "reminder_hour" => "19"})
    refute Reminders.settings().reminders_enabled

    html = render_hook(view, "save_settings", %{"reminders_enabled" => "true", "reminder_hour" => "99"})
    assert html =~ "between 0 and 23"
  end

  test "previews what today's reminder would say", %{conn: conn} do
    challenge_fixture(%{"plan" => "daily", "name" => "Trip fund", "start_amount" => 200})
    {:ok, _view, html} = live(conn, "/reminders")
    assert html =~ "What you&#39;d get today"
    assert html =~ "Trip fund"
    assert html =~ "KSh 200"
  end

  test "without server keys the page says push is not set up", %{conn: conn} do
    original = Application.get_env(:savings_challenge, :vapid)
    Application.delete_env(:savings_challenge, :vapid)
    on_exit(fn -> Application.put_env(:savings_challenge, :vapid, original) end)

    {:ok, _view, html} = live(conn, "/reminders")
    assert html =~ "not set up on the server yet"
  end

  describe "scheduler endpoint" do
    test "rejects requests without the right secret", %{conn: conn} do
      assert json_response(get(conn, "/cron/reminders"), 401)
      assert json_response(get(conn, "/cron/reminders?key=wrong"), 401)
      assert json_response(post(conn, "/cron/reminders", %{}), 401)
      conn = conn |> put_req_header("authorization", "Bearer nope") |> get("/cron/reminders")
      assert json_response(conn, 401)
    end

    test "is closed when no secret is configured", %{conn: conn} do
      original = Application.get_env(:savings_challenge, :cron_secret)
      Application.delete_env(:savings_challenge, :cron_secret)
      on_exit(fn -> Application.put_env(:savings_challenge, :cron_secret, original) end)

      assert json_response(get(conn, "/cron/reminders?key="), 401)
      conn = conn |> put_req_header("authorization", "Bearer ") |> get("/cron/reminders")
      assert json_response(conn, 401)
    end

    test "accepts a bearer header or ?key= and runs the reminder", %{conn: conn} do
      assert %{"status" => "skipped", "reason" => "no_devices"} =
               conn |> put_req_header("authorization", "Bearer test-secret") |> get("/cron/reminders") |> json_response(200)

      assert %{"status" => "skipped"} = conn |> get("/cron/reminders?key=test-secret") |> json_response(200)
    end

    test "works even when a PIN is set (the scheduler has no session)", %{conn: conn} do
      :ok = SavingsChallenge.Lock.set_pin("1234", "me@example.com")
      assert %{"status" => "skipped"} = conn |> put_req_header("authorization", "Bearer test-secret") |> get("/cron/reminders") |> json_response(200)
      assert redirected_to(get(build_conn(), "/reminders")) == "/unlock"
    end
  end
end
