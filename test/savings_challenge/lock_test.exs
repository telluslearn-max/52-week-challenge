defmodule SavingsChallenge.LockTest do
  use SavingsChallenge.DataCase

  alias SavingsChallenge.{AppSettings, Lock}
  alias SavingsChallenge.Mailer.Inbox

  setup do
    Inbox.clear()
    :ok
  end

  test "no PIN until one is set; validation of pin and email" do
    refute Lock.pin_set?()
    assert {:error, :invalid_pin} = Lock.set_pin("12", "me@example.com")
    assert {:error, :invalid_pin} = Lock.set_pin("12a4", "me@example.com")
    assert {:error, :invalid_pin} = Lock.set_pin("1234567", "me@example.com")
    assert {:error, :invalid_email} = Lock.set_pin("1234", "not-an-email")
    refute Lock.pin_set?()
  end

  test "set, verify and the stored PIN is not plain text" do
    assert :ok = Lock.set_pin("1234", "me@example.com")
    assert Lock.pin_set?()
    assert Lock.pin_length() == 4
    assert :ok = Lock.verify_pin("1234")
    assert {:error, {:bad, 4}} = Lock.verify_pin("0000")

    s = Lock.get()
    refute s.pin_hash =~ "1234"
    assert {:error, :already_set} = Lock.set_pin("9999", "other@example.com")
    assert :ok = Lock.verify_pin("1234")
  end

  test "six digit PIN" do
    assert :ok = Lock.set_pin("123456", "me@example.com")
    assert Lock.pin_length() == 6
    assert :ok = Lock.verify_pin("123456")
  end

  test "five wrong tries lock the PIN, even for the right PIN, until it expires" do
    :ok = Lock.set_pin("1234", "me@example.com")

    assert {:error, {:bad, 4}} = Lock.verify_pin("1111")
    assert {:error, {:bad, 3}} = Lock.verify_pin("1111")
    assert {:error, {:bad, 2}} = Lock.verify_pin("1111")
    assert {:error, {:bad, 1}} = Lock.verify_pin("1111")
    assert {:error, {:locked, secs}} = Lock.verify_pin("1111")
    assert secs in 55..60

    assert {:error, {:locked, _}} = Lock.verify_pin("1234")
    assert Lock.locked_seconds() > 0

    # Lockout over: the next wrong try locks for longer, a right one resets everything.
    past = DateTime.utc_now() |> DateTime.add(-5) |> DateTime.truncate(:second)
    Repo.update_all(AppSettings, set: [locked_until: past])
    assert :ok = Lock.verify_pin("1234")
    assert %{failed_attempts: 0, locked_until: nil} = Lock.get()
  end

  test "repeat offenders are locked for longer" do
    :ok = Lock.set_pin("1234", "me@example.com")
    Repo.update_all(AppSettings, set: [failed_attempts: 5])
    assert {:error, {:locked, secs}} = Lock.verify_pin("1111")
    assert secs in 295..300
  end

  test "change PIN needs the current one" do
    :ok = Lock.set_pin("1234", "me@example.com")
    assert {:error, {:bad, _}} = Lock.change_pin("0000", "5678")
    assert {:error, :invalid_pin} = Lock.change_pin("1234", "5")
    assert :ok = Lock.change_pin("1234", "5678")
    assert :ok = Lock.verify_pin("5678")
    assert {:error, {:bad, _}} = Lock.verify_pin("1234")
  end

  describe "reset by email" do
    setup do
      :ok = Lock.set_pin("1234", "tester@example.com")
      Inbox.clear()
    end

    defp token_from_inbox do
      [%{to: to, text: text} | _] = Inbox.all()
      assert to == "tester@example.com"
      [_, token] = Regex.run(~r{/unlock/reset/([\w-]+)}, text)
      token
    end

    test "emails a single-use link that sets a new PIN" do
      assert {:ok, "t*****@example.com"} = Lock.request_reset()
      token = token_from_inbox()

      assert Lock.valid_reset_token?(token)
      refute Lock.valid_reset_token?("wrong")
      assert {:error, :invalid_pin} = Lock.reset_pin(token, "12")

      assert :ok = Lock.reset_pin(token, "4321")
      assert :ok = Lock.verify_pin("4321")

      # Used once only.
      refute Lock.valid_reset_token?(token)
      assert {:error, :invalid_token} = Lock.reset_pin(token, "1111")
    end

    test "reset also clears a lockout" do
      Repo.update_all(AppSettings, set: [failed_attempts: 6, locked_until: DateTime.add(DateTime.utc_now(), 600) |> DateTime.truncate(:second)])
      {:ok, _} = Lock.request_reset()
      :ok = Lock.reset_pin(token_from_inbox(), "2468")
      assert Lock.locked_seconds() == 0
      assert :ok = Lock.verify_pin("2468")
    end

    test "requests are rate limited and tokens expire" do
      assert {:ok, _} = Lock.request_reset()
      assert {:error, :too_soon} = Lock.request_reset()
      assert length(Inbox.all()) == 1

      token = token_from_inbox()
      Repo.update_all(AppSettings, set: [reset_expires_at: DateTime.add(DateTime.utc_now(), -1) |> DateTime.truncate(:second)])
      refute Lock.valid_reset_token?(token)
    end
  end
end
