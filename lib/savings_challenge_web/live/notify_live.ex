defmodule SavingsChallengeWeb.NotifyLive do
  @moduledoc "Reminder settings: turn push notifications on for this device, pick the hour, send a test."
  use SavingsChallengeWeb, :live_view

  import SavingsChallengeWeb.Format

  alias SavingsChallenge.{Push, Reminders}

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(page_title: "Reminders", notice: nil, device: %{supported: nil, permission: "default", subscribed: false, endpoint: nil})
     |> assign(enabled?: Push.enabled?(), public_key: Push.public_key())
     |> load()}
  end

  defp load(socket) do
    settings = Reminders.settings()
    digest = Reminders.current_digest()

    assign(socket,
      devices: Push.count(),
      reminders_enabled: settings.reminders_enabled,
      hour: settings.reminder_hour,
      digest: digest
    )
  end

  defp notify(socket, message), do: assign(socket, notice: {System.unique_integer([:positive]), message})

  ## Events from the browser hook

  @impl true
  def handle_event("push_state", params, socket) do
    device = %{
      supported: params["supported"] == true,
      permission: params["permission"] || "default",
      subscribed: params["subscribed"] == true,
      endpoint: params["endpoint"]
    }

    {:noreply, assign(socket, device: device)}
  end

  def handle_event("subscribe", %{"endpoint" => endpoint, "p256dh" => p256dh, "auth" => auth} = params, socket) do
    attrs = %{endpoint: endpoint, p256dh: p256dh, auth: auth, user_agent: String.slice(params["user_agent"] || "", 0, 250)}

    case Push.subscribe(attrs) do
      {:ok, _} -> {:noreply, socket |> load() |> notify("Notifications are on for this device")}
      {:error, _} -> {:noreply, notify(socket, "Could not turn notifications on for this device")}
    end
  end

  def handle_event("unsubscribe", %{"endpoint" => endpoint}, socket) when is_binary(endpoint) do
    Push.unsubscribe(endpoint)
    {:noreply, socket |> load() |> notify("Notifications are off for this device")}
  end

  def handle_event("unsubscribe", _params, socket), do: {:noreply, socket}

  ## Settings

  def handle_event("save_settings", params, socket) do
    attrs = %{reminders_enabled: params["reminders_enabled"] == "true", reminder_hour: params["reminder_hour"]}

    case Reminders.update_settings(attrs) do
      {:ok, _} -> {:noreply, socket |> load() |> notify("Saved")}
      {:error, _} -> {:noreply, notify(socket, "Pick an hour between 0 and 23")}
    end
  end

  def handle_event("send_test", _params, socket) do
    cond do
      not Push.enabled?() -> {:noreply, notify(socket, "Notifications are not set up on the server yet")}
      Push.count() == 0 -> {:noreply, notify(socket, "Turn notifications on for a device first")}
      true ->
        r = Reminders.send_test()
        {:noreply, socket |> load() |> notify("Test sent to #{r.sent} #{if r.sent == 1, do: "device", else: "devices"}#{if r.removed > 0, do: " (#{r.removed} expired removed)", else: ""}")}
    end
  end

  ## Render

  @impl true
  def render(assigns) do
    ~H"""
    <div class="loadbar" aria-hidden="true"></div>
    <main class="app has-tabbar">
      <div :if={@notice} id={"notice-#{elem(@notice, 0)}"} class="notice" role="status">{elem(@notice, 1)}</div>

      <header class="topbar">
        <div class="title">
          <.link navigate="/" class="back">‹ All goals</.link>
          <p class="eyebrow">Notifications</p>
          <h1>Reminders</h1>
        </div>
      </header>

      <section class="card">
        <div class="section-head"><h2>This device</h2></div>

        <div id="push" phx-hook="Push" data-key={@public_key} class="push-box">
          <%= cond do %>
            <% !@enabled? -> %>
              <p class="muted">Push notifications are not set up on the server yet.</p>
            <% @device.supported == nil -> %>
              <p class="muted">Checking this device…</p>
            <% !@device.supported -> %>
              <p><strong>This browser can't show notifications here.</strong></p>
              <p class="muted">On iPhone, first add the app to your Home Screen (Share, then Add to Home Screen) and open it from there. It needs iOS 16.4 or newer.</p>
            <% @device.permission == "denied" -> %>
              <p><strong>Notifications are blocked.</strong></p>
              <p class="muted">Allow them for this site in your browser or phone settings, then come back.</p>
            <% @device.subscribed -> %>
              <p class="ok-line">✓ Notifications are on for this device.</p>
              <div class="push-actions">
                <button type="button" class="btn btn-primary" phx-click="send_test" phx-disable-with="Sending…">Send a test</button>
                <button type="button" class="btn btn-ghost" data-push="disable">Turn off</button>
              </div>
            <% true -> %>
              <p class="muted">Get a nudge when it's time to save, and when a bill is due soon.</p>
              <button type="button" class="btn btn-primary btn-block" data-push="enable">Turn on notifications</button>
          <% end %>
        </div>
        <p :if={@devices > 0} class="muted devices">{@devices} {if @devices == 1, do: "device", else: "devices"} will get reminders.</p>
      </section>

      <section class="card">
        <div class="section-head"><h2>Daily reminder</h2></div>
        <form phx-change="save_settings" id="reminder-form" class="form" style="margin-top:0">
          <label class="switch">
            <input type="hidden" name="reminders_enabled" value="false" />
            <input type="checkbox" name="reminders_enabled" value="true" checked={@reminders_enabled} />
            <span>Send me a reminder each day</span>
          </label>
          <label class="field">
            <span>Time</span>
            <select name="reminder_hour">
              <option :for={h <- 5..22} value={h} selected={@hour == h}>{hour_label(h)}</option>
            </select>
            <small class="muted">Nairobi time. It's sent the first time the scheduler checks after this hour.</small>
          </label>
        </form>
      </section>

      <section class="card">
        <div class="section-head"><h2>What you'd get today</h2></div>
        <%= if @digest.items == [] and @digest.due_soon == [] do %>
          <p class="muted">Nothing to save right now. You're all caught up.</p>
        <% else %>
          <ul class="deposits">
            <li :for={i <- @digest.items}>
              <div><strong>{ksh(i.amount)}</strong><span class="muted">{i.name}</span></div>
            </li>
            <li :for={b <- @digest.due_soon}>
              <div><strong>{b.name}</strong><span class="muted">due {if b.days == 0, do: "today", else: if(b.days == 1, do: "tomorrow", else: "in #{b.days} days")}</span></div>
            </li>
          </ul>
          <p :if={@digest.total > 0} class="muted">Total today: <strong>{ksh(@digest.total)}</strong></p>
        <% end %>
      </section>
    </main>
    <SavingsChallengeWeb.Layouts.bottom_nav active={:reminders} lock_href={if SavingsChallenge.Lock.pin_set?(), do: "/lock", else: "/unlock/setup"} />
    """
  end

  defp hour_label(h) when h == 12, do: "12:00 noon"
  defp hour_label(h) when h < 12, do: "#{h}:00 am"
  defp hour_label(h), do: "#{h - 12}:00 pm"
end
