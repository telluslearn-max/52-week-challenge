defmodule SavingsChallengeWeb.LockLive do
  @moduledoc """
  PIN screens with an M-Pesa-style keypad: unlock, first-time setup, change PIN,
  and reset via the emailed link. The PIN is checked here; the browser is then
  sent to `SessionController.complete/2` with a short-lived token, which is the
  only place that marks the session unlocked.
  """
  use SavingsChallengeWeb, :live_view

  alias SavingsChallenge.Lock
  alias SavingsChallengeWeb.Plugs.RequirePin

  @digits ~w(0 1 2 3 4 5 6 7 8 9)

  @impl true
  def mount(params, session, socket) do
    unlocked? = RequirePin.unlocked?(session)
    socket = assign(socket, page_title: "Unlock", entry: "", error: nil, shake: false, notice: nil)
    socket = assign(socket, email: nil, first_pin: nil, current_pin: nil, token: params["token"], masked: nil)

    case socket.assigns.live_action do
      :enter ->
        cond do
          not Lock.pin_set?() -> {:ok, redirect(socket, to: "/")}
          unlocked? -> {:ok, redirect(socket, to: "/")}
          true -> {:ok, start(socket, :enter, Lock.pin_length())}
        end

      :setup ->
        cond do
          Lock.pin_set?() -> {:ok, redirect(socket, to: "/unlock")}
          setup_code() -> {:ok, start(socket, :code, 4)}
          true -> {:ok, start(socket, :email, 4)}
        end

      :change ->
        if unlocked? and Lock.pin_set?(),
          do: {:ok, start(socket, :current, Lock.pin_length())},
          else: {:ok, redirect(socket, to: "/unlock")}

      :reset ->
        if Lock.valid_reset_token?(params["token"]),
          do: {:ok, start(socket, :pin, Lock.pin_length())},
          else: {:ok, start(socket, :bad_link, 4)}
    end
  end

  defp start(socket, step, length) do
    socket |> assign(step: step, length: length) |> show_lockout()
  end

  defp setup_code, do: Application.get_env(:savings_challenge, :setup_code)

  ## Keypad

  @impl true
  def handle_event("digit", %{"d" => d}, socket) when d in @digits do
    entry = socket.assigns.entry <> d

    if String.length(entry) > socket.assigns.length do
      {:noreply, socket}
    else
      socket = assign(socket, entry: entry, error: nil, shake: false)
      if String.length(entry) == socket.assigns.length, do: submit_pin(socket), else: {:noreply, socket}
    end
  end

  def handle_event("del", _params, socket) do
    {:noreply, assign(socket, entry: String.slice(socket.assigns.entry, 0..-2//1), error: nil)}
  end

  def handle_event("set_length", %{"len" => len}, %{assigns: %{step: :pin, entry: ""}} = socket) when len in ["4", "6"] do
    {:noreply, assign(socket, length: String.to_integer(len))}
  end

  def handle_event("set_length", _params, socket), do: {:noreply, socket}

  ## Text steps

  def handle_event("submit_code", %{"code" => code}, socket) do
    expected = setup_code() || ""

    if Plug.Crypto.secure_compare(String.trim(code), expected) do
      {:noreply, assign(socket, step: :email, error: nil)}
    else
      {:noreply, assign(socket, error: "That setup code is not right.")}
    end
  end

  def handle_event("submit_email", %{"email" => email}, socket) do
    email = String.trim(email)

    if Lock.valid_email?(email) do
      {:noreply, assign(socket, email: email, step: :pin, entry: "", error: nil)}
    else
      {:noreply, assign(socket, error: "Enter a valid email address.")}
    end
  end

  def handle_event("forgot", _params, socket), do: {:noreply, assign(socket, step: :forgot, error: nil, notice: nil)}
  def handle_event("back_to_pin", _params, socket), do: {:noreply, assign(socket, step: :enter, entry: "", error: nil, notice: nil)}

  def handle_event("send_reset", _params, socket) do
    case Lock.request_reset() do
      {:ok, masked} ->
        {:noreply, assign(socket, masked: masked, notice: "sent", error: nil)}

      {:error, :too_soon} ->
        {:noreply, assign(socket, error: "A link was just sent. Check your inbox, or wait a minute to ask again.")}

      {:error, _} ->
        {:noreply, assign(socket, error: "Could not send the email right now. Try again in a few minutes.")}
    end
  end

  ## PIN submission per step

  defp submit_pin(%{assigns: %{step: :enter, entry: pin}} = socket), do: check_current(socket, pin, :unlock)
  defp submit_pin(%{assigns: %{step: :current, entry: pin}} = socket), do: check_current(socket, pin, :change)

  defp submit_pin(%{assigns: %{step: :pin, entry: pin}} = socket) do
    {:noreply, assign(socket, step: :confirm, first_pin: pin, entry: "")}
  end

  defp submit_pin(%{assigns: %{step: :confirm, entry: pin, first_pin: pin}} = socket), do: finish(socket, pin)

  defp submit_pin(%{assigns: %{step: :confirm}} = socket) do
    {:noreply, socket |> assign(step: :pin, entry: "", first_pin: nil) |> mistake("The two PINs did not match. Start again.")}
  end

  defp check_current(socket, pin, next) do
    case Lock.verify_pin(pin) do
      :ok when next == :unlock -> {:noreply, unlock(socket)}
      :ok -> {:noreply, assign(socket, step: :pin, current_pin: pin, entry: "", error: nil)}
      {:error, {:bad, left}} -> {:noreply, mistake(socket, "Wrong PIN. #{left} #{if left == 1, do: "try", else: "tries"} left.")}
      {:error, {:locked, secs}} -> {:noreply, mistake(socket, locked_message(secs))}
      {:error, _} -> {:noreply, mistake(socket, "Something went wrong. Try again.")}
    end
  end

  defp finish(socket, pin) do
    a = socket.assigns

    result =
      case socket.assigns.live_action do
        :setup -> Lock.set_pin(pin, a.email)
        :change -> Lock.change_pin(a.current_pin, pin)
        :reset -> Lock.reset_pin(a.token, pin)
      end

    case result do
      :ok -> {:noreply, unlock(socket)}
      {:error, :invalid_token} -> {:noreply, assign(start(socket, :bad_link, 4), error: nil)}
      {:error, _} -> {:noreply, socket |> assign(step: :pin, entry: "", first_pin: nil) |> mistake("Could not save that PIN. Try again.")}
    end
  end

  defp unlock(socket) do
    token = Phoenix.Token.sign(SavingsChallengeWeb.Endpoint, "unlock", 1)
    redirect(socket, to: "/unlock/complete?t=#{token}")
  end

  defp mistake(socket, message), do: assign(socket, entry: "", error: message, shake: true)

  defp show_lockout(socket) do
    case Lock.locked_seconds() do
      0 -> socket
      secs when socket.assigns.step in [:enter, :current] -> assign(socket, error: locked_message(secs))
      _ -> socket
    end
  end

  defp locked_message(secs) when secs >= 90, do: "Too many wrong tries. Try again in #{div(secs + 59, 60)} minutes."
  defp locked_message(secs), do: "Too many wrong tries. Try again in #{max(secs, 1)} seconds."

  ## Render

  @impl true
  def render(assigns) do
    ~H"""
    <main class="app lock">
      <div class="lock-head">
        <div class="lock-icon" aria-hidden="true">🔒</div>
        <h1>{title(@step, @live_action)}</h1>
        <p :if={subtitle(@step, @live_action)} class="muted">{subtitle(@step, @live_action)}</p>
      </div>

      <p :if={@error} class="lock-error" role="alert">{@error}</p>

      <%= case @step do %>
        <% :code -> %>
          <form phx-submit="submit_code" class="form lock-form" id="code-form">
            <label class="field">
              <span>Setup code</span>
              <input type="password" name="code" autocomplete="off" required />
            </label>
            <button class="btn btn-primary btn-block" type="submit">Continue</button>
          </form>
        <% :email -> %>
          <form phx-submit="submit_email" class="form lock-form" id="email-form">
            <label class="field">
              <span>Recovery email</span>
              <input type="email" name="email" value={@email} autocomplete="email" placeholder="you@example.com" required />
              <small class="muted">Used only to email a link if you forget your PIN.</small>
            </label>
            <button class="btn btn-primary btn-block" type="submit">Continue</button>
          </form>
        <% :forgot -> %>
          <div class="form lock-form">
            <%= if @notice == "sent" do %>
              <p class="chosen">Check {@masked}. The link works once and expires in 30 minutes.</p>
            <% else %>
              <p class="muted">We will email a one-time link to the recovery email you chose when you created the PIN.</p>
              <button class="btn btn-primary btn-block" phx-click="send_reset" phx-disable-with="Sending…">Email me a reset link</button>
            <% end %>
            <button class="btn btn-ghost btn-block" phx-click="back_to_pin">Back</button>
          </div>
        <% :bad_link -> %>
          <div class="form lock-form">
            <p class="muted">This reset link is invalid or has expired.</p>
            <a class="btn btn-primary btn-block" href="/unlock">Back to the PIN screen</a>
          </div>
        <% _pin_step -> %>
          <div class={["dots", @shake && "shake"]} role="img" aria-label={"#{String.length(@entry)} of #{@length} digits entered"}>
            <i :for={i <- 1..@length} class={i <= String.length(@entry) && "on"}></i>
          </div>

          <div :if={@step == :pin and @live_action == :setup} class="len-toggle" role="group" aria-label="PIN length">
            <button type="button" class={["chip", @length == 4 && "on"]} phx-click="set_length" phx-value-len="4">4 digits</button>
            <button type="button" class={["chip", @length == 6 && "on"]} phx-click="set_length" phx-value-len="6">6 digits</button>
          </div>

          <div class="pad">
            <button :for={d <- ~w(1 2 3 4 5 6 7 8 9)} type="button" phx-click="digit" phx-value-d={d} aria-label={d}>{d}</button>
            <span></span>
            <button type="button" phx-click="digit" phx-value-d="0" aria-label="0">0</button>
            <button type="button" phx-click="del" aria-label="Delete">⌫</button>
          </div>

          <button :if={@step == :enter} type="button" class="btn btn-ghost" phx-click="forgot">Forgot PIN?</button>
          <a :if={@live_action in [:change, :reset] and @step != :bad_link} class="back lock-cancel" href="/">Cancel</a>
      <% end %>
    </main>
    """
  end

  defp title(:enter, _), do: "Enter your PIN"
  defp title(:current, _), do: "Enter your current PIN"
  defp title(:pin, :setup), do: "Create your PIN"
  defp title(:pin, :reset), do: "Choose a new PIN"
  defp title(:pin, _), do: "Choose a new PIN"
  defp title(:confirm, _), do: "Confirm your PIN"
  defp title(:code, _), do: "Welcome"
  defp title(:email, _), do: "Create your PIN"
  defp title(:forgot, _), do: "Forgot your PIN?"
  defp title(:bad_link, _), do: "Link expired"

  defp subtitle(:enter, _), do: "Your savings are locked."
  defp subtitle(:code, _), do: "Enter the setup code you were given to protect this app."
  defp subtitle(:email, _), do: "Step 1 of 2: where should we send a reset link?"
  defp subtitle(:pin, :setup), do: "Step 2 of 2: pick 4 or 6 digits you will remember."
  defp subtitle(_, _), do: nil
end
