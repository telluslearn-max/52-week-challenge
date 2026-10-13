defmodule SavingsChallenge.Lock do
  @moduledoc """
  The app-wide PIN (a single-user app has a single PIN).

  * PINs are 4 or 6 digits, stored as PBKDF2-SHA256 of an HMAC "pepper" (the
    app secret) with a random salt, compared in constant time.
  * 5 wrong tries lock the PIN for a growing time (1 min, 5 min, 25 min, 1 h).
  * A forgotten PIN is reset through a single-use link emailed to the
    recovery email chosen at setup (valid 30 minutes, 1 request per minute).
  """
  import Ecto.Query

  alias SavingsChallenge.{AppSettings, Mailer, Repo}

  @iterations 120_000
  @max_free_attempts 5
  @reset_ttl 30 * 60
  @reset_cooldown 60

  ## Reading

  def get do
    Repo.insert(%AppSettings{id: 1}, on_conflict: :nothing, conflict_target: :id)
    Repo.get!(AppSettings, 1)
  end

  def pin_set?, do: not is_nil(get().pin_hash)
  def pin_length, do: get().pin_length

  @doc "Seconds left on a lockout, or 0."
  def locked_seconds(%AppSettings{locked_until: nil}), do: 0

  def locked_seconds(%AppSettings{locked_until: until}),
    do: max(DateTime.diff(until, DateTime.utc_now()), 0)

  def locked_seconds, do: locked_seconds(get())

  ## Validation

  def valid_pin?(pin), do: is_binary(pin) and Regex.match?(~r/\A(\d{4}|\d{6})\z/, pin)
  def valid_email?(email), do: is_binary(email) and Regex.match?(~r/\A[^\s@]+@[^\s@]+\.[^\s@]+\z/, email) and String.length(email) <= 160

  ## Setting and changing

  @doc "First-time setup. Fails if a PIN already exists."
  def set_pin(pin, email) do
    cond do
      not valid_pin?(pin) -> {:error, :invalid_pin}
      not valid_email?(email) -> {:error, :invalid_email}
      true -> transact(fn s -> if s.pin_hash, do: {:error, :already_set}, else: store_pin(s, pin, %{recovery_email: String.trim(email)}) end)
    end
  end

  @doc "Changes the PIN after checking the current one."
  def change_pin(current, new) do
    with true <- valid_pin?(new) || {:error, :invalid_pin},
         :ok <- verify_pin(current) do
      transact(&store_pin(&1, new, %{}))
    end
  end

  defp store_pin(settings, pin, extra) do
    salt = :crypto.strong_rand_bytes(16)

    changes =
      Map.merge(
        %{
          pin_hash: hash(pin, salt),
          pin_salt: Base.encode64(salt),
          pin_length: String.length(pin),
          failed_attempts: 0,
          locked_until: nil,
          reset_token_hash: nil,
          reset_expires_at: nil
        },
        extra
      )

    settings |> Ecto.Changeset.change(changes) |> Repo.update() |> ok()
  end

  ## Checking

  @doc "Returns :ok, {:error, {:bad, tries_left}} or {:error, {:locked, seconds}}."
  def verify_pin(pin) do
    transact(fn s ->
      cond do
        is_nil(s.pin_hash) ->
          {:error, :no_pin}

        locked_seconds(s) > 0 ->
          {:error, {:locked, locked_seconds(s)}}

        matches?(s, pin) ->
          s |> Ecto.Changeset.change(failed_attempts: 0, locked_until: nil) |> Repo.update()
          :ok

        true ->
          attempts = s.failed_attempts + 1

          until =
            if attempts >= @max_free_attempts do
              seconds = min(60 * Integer.pow(5, attempts - @max_free_attempts), 3600)
              DateTime.utc_now() |> DateTime.add(seconds) |> DateTime.truncate(:second)
            end

          s |> Ecto.Changeset.change(failed_attempts: attempts, locked_until: until) |> Repo.update()

          # {:keep, _} commits the attempt counter even though the check failed.
          if until,
            do: {:keep, {:error, {:locked, DateTime.diff(until, DateTime.utc_now())}}},
            else: {:keep, {:error, {:bad, @max_free_attempts - attempts}}}
      end
    end)
  end

  defp matches?(s, pin) when is_binary(pin) do
    salt = Base.decode64!(s.pin_salt)
    Plug.Crypto.secure_compare(hash(pin, salt), s.pin_hash)
  end

  defp matches?(_s, _pin), do: false

  defp hash(pin, salt) do
    pepper = :crypto.mac(:hmac, :sha256, secret(), pin)
    :crypto.pbkdf2_hmac(:sha256, pepper, salt, @iterations, 32) |> Base.encode64()
  end

  defp secret, do: SavingsChallengeWeb.Endpoint.config(:secret_key_base)

  ## Reset by email

  @doc "Emails a single-use reset link. Returns {:ok, masked_email} or {:error, reason}."
  def request_reset do
    s = get()
    now = DateTime.utc_now()

    cond do
      is_nil(s.pin_hash) or is_nil(s.recovery_email) ->
        {:error, :no_pin}

      s.reset_sent_at && DateTime.diff(now, s.reset_sent_at) < @reset_cooldown ->
        {:error, :too_soon}

      true ->
        token = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)

        s
        |> Ecto.Changeset.change(
          reset_token_hash: token_hash(token),
          reset_expires_at: now |> DateTime.add(@reset_ttl) |> DateTime.truncate(:second),
          reset_sent_at: DateTime.truncate(now, :second)
        )
        |> Repo.update!()

        url = SavingsChallengeWeb.Endpoint.url() <> "/unlock/reset/" <> token

        body = """
        Someone asked to reset the PIN for your savings app. If it was you, open this link within 30 minutes and choose a new PIN:

        #{url}

        If it wasn't you, ignore this email. Your PIN has not changed.
        """

        case Mailer.deliver(s.recovery_email, "Reset your savings PIN", body) do
          :ok -> {:ok, mask_email(s.recovery_email)}
          {:error, _} -> {:error, :email_failed}
        end
    end
  end

  def valid_reset_token?(token) when is_binary(token) do
    s = get()

    not is_nil(s.reset_token_hash) and
      Plug.Crypto.secure_compare(token_hash(token), s.reset_token_hash) and
      DateTime.compare(s.reset_expires_at, DateTime.utc_now()) == :gt
  end

  def valid_reset_token?(_), do: false

  @doc "Sets a new PIN using a reset token; the token is single-use."
  def reset_pin(token, new_pin) do
    cond do
      not valid_pin?(new_pin) ->
        {:error, :invalid_pin}

      true ->
        transact(fn s ->
          if valid_reset_token?(token), do: store_pin(s, new_pin, %{}), else: {:error, :invalid_token}
        end)
    end
  end

  defp token_hash(token), do: :crypto.hash(:sha256, token) |> Base.encode64()

  def mask_email(email) do
    [name, domain] = String.split(email, "@", parts: 2)
    String.first(name) <> String.duplicate("*", max(String.length(name) - 1, 2)) <> "@" <> domain
  end

  ## Helpers

  # Runs fun with the settings row locked so concurrent attempts are counted correctly.
  defp transact(fun) do
    result =
      Repo.transaction(fn ->
        _ = get()
        s = Repo.one!(from a in AppSettings, where: a.id == 1, lock: "FOR UPDATE")

        case fun.(s) do
          {:error, reason} -> Repo.rollback(reason)
          {:keep, value} -> value
          other -> other
        end
      end)

    case result do
      {:ok, :ok} -> :ok
      {:ok, value} -> value
      {:error, reason} -> {:error, reason}
    end
  end

  defp ok({:ok, _}), do: :ok
  defp ok(other), do: other
end
