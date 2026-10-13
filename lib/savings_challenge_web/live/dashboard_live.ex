defmodule SavingsChallengeWeb.DashboardLive do
  use SavingsChallengeWeb, :live_view

  import SavingsChallengeWeb.Format

  alias SavingsChallenge.{Challenge, Clock, Contribution, Plan, Savings}

  @ring_radius 52
  @ring_circumference 2 * :math.pi() * @ring_radius

  ## Lifecycle

  @impl true
  def mount(params, _session, socket) do
    case fetch_challenge(params) do
      :not_found ->
        {:ok, push_navigate(socket, to: "/")}

      challenge ->
        socket =
          socket
          |> assign(page_title: if(challenge, do: challenge.name, else: "New goal"))
          |> assign(challenge: challenge, editing: nil, notice: nil, confirm_delete: false)
          |> assign(has_goals: Savings.count_challenges() > 0)
          |> assign(settings_open: false, settings_form: nil, settings_preview: nil)
          |> load()

        socket =
          if challenge do
            socket |> assign(selected: socket.assigns.snap.current_week) |> reset_deposit_form()
          else
            socket |> assign(selected: 1, deposit_form: nil) |> open_settings()
          end

        {:ok, socket}
    end
  end

  defp fetch_challenge(%{"id" => id}), do: Savings.get_challenge(id) || :not_found
  defp fetch_challenge(_params), do: nil

  ## Week selection & deposits

  @impl true
  def handle_event("select_week", %{"week" => week}, socket) do
    case Integer.parse(week) do
      {w, ""} when w in 1..52 ->
        {:noreply, socket |> assign(selected: w, editing: nil) |> reset_deposit_form()}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("validate_deposit", %{"deposit" => params}, socket) do
    changeset =
      %Contribution{}
      |> Savings.change_contribution(deposit_attrs(socket, params))
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, deposit_form: to_form(changeset, as: :deposit))}
  end

  def handle_event("save_deposit", %{"deposit" => params}, socket) do
    attrs = deposit_attrs(socket, params)

    result =
      case socket.assigns.editing do
        nil -> Savings.create_contribution(socket.assigns.challenge, attrs)
        id -> Savings.update_contribution(socket.assigns.challenge, id, attrs)
      end

    case result do
      {:ok, _} ->
        message = if socket.assigns.editing, do: "Deposit updated", else: "Deposit saved"
        {:noreply, socket |> assign(editing: nil) |> load() |> reset_deposit_form() |> notify(message)}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, deposit_form: to_form(Map.put(changeset, :action, :validate), as: :deposit))}
    end
  end

  # One-tap "I saved this week's amount".
  def handle_event("pay_week", _params, socket) do
    week = Enum.at(socket.assigns.snap.weeks, socket.assigns.selected - 1)

    attrs = %{
      "week" => week.week,
      "amount" => max(week.target - week.paid, 0),
      "deposited_on" => Date.to_iso8601(Clock.today()),
      "idempotency_key" => socket.assigns.deposit_form[:idempotency_key].value
    }

    case Savings.create_contribution(socket.assigns.challenge, attrs) do
      {:ok, _} -> {:noreply, socket |> load() |> reset_deposit_form() |> notify("Week #{week.week} saved")}
      {:error, _} -> {:noreply, notify(socket, "Nothing left to save for this week")}
    end
  end

  def handle_event("edit_deposit", %{"id" => id}, socket) do
    case Enum.find(socket.assigns.contributions, &(to_string(&1.id) == id)) do
      nil ->
        {:noreply, socket}

      contribution ->
        form = contribution |> Savings.change_contribution() |> to_form(as: :deposit)
        {:noreply, assign(socket, editing: contribution.id, deposit_form: form)}
    end
  end

  def handle_event("cancel_edit", _params, socket) do
    {:noreply, socket |> assign(editing: nil) |> reset_deposit_form()}
  end

  def handle_event("delete_deposit", %{"id" => id}, socket) do
    {:ok, _} = Savings.delete_contribution(socket.assigns.challenge, id)
    {:noreply, socket |> assign(editing: nil) |> load() |> reset_deposit_form() |> notify("Deposit deleted")}
  end

  ## Settings

  def handle_event("open_settings", _params, socket), do: {:noreply, open_settings(socket)}

  def handle_event("close_settings", _params, %{assigns: %{challenge: nil}} = socket), do: {:noreply, socket}
  def handle_event("close_settings", _params, socket),
    do: {:noreply, assign(socket, settings_open: false, confirm_delete: false)}

  def handle_event("validate_settings", %{"challenge" => params} = all, socket) do
    params = maybe_fit_plan(params, all["_target"])
    {:noreply, assign_settings(socket, settings_changeset(socket, params) |> Map.put(:action, :validate))}
  end

  def handle_event("ask_delete_goal", _params, socket), do: {:noreply, assign(socket, confirm_delete: true)}

  def handle_event("delete_goal", _params, %{assigns: %{challenge: %Challenge{} = challenge}} = socket) do
    {:ok, _} = Savings.delete_challenge(challenge)
    {:noreply, push_navigate(socket, to: "/")}
  end

  def handle_event("save_settings", %{"challenge" => params}, socket) do
    result =
      case socket.assigns.challenge do
        nil -> Savings.create_challenge(params)
        challenge -> Savings.update_challenge(challenge, params)
      end

    case result do
      {:ok, challenge} when is_nil(socket.assigns.challenge) ->
        {:noreply, push_navigate(socket, to: "/goals/#{challenge.id}")}

      {:ok, challenge} ->
        socket =
          socket
          |> assign(challenge: challenge, page_title: challenge.name, settings_open: false, editing: nil)
          |> load()
          |> reset_deposit_form()
          |> notify("Plan updated")

        {:noreply, socket}

      {:error, changeset} ->
        {:noreply, assign_settings(socket, Map.put(changeset, :action, :validate))}
    end
  end

  # When the goal amount is what the user just edited, suggest weekly amounts
  # whose 52-week total reaches it. Editing the amounts afterwards is left alone.
  defp maybe_fit_plan(params, ["challenge", "target_amount"]) do
    case Integer.parse(String.trim(params["target_amount"] || "")) do
      {goal, ""} when goal > 0 ->
        if params["mode"] == "fixed" do
          Map.put(params, "start_amount", ceil_div(goal, Plan.weeks()))
        else
          amount = ceil_div(goal, div(Plan.weeks() * (Plan.weeks() + 1), 2))
          params |> Map.put("start_amount", amount) |> Map.put("increment", amount)
        end

      _ ->
        params
    end
  end

  defp maybe_fit_plan(params, _target), do: params

  defp ceil_div(a, b), do: div(a + b - 1, b)

  ## State helpers

  defp load(%{assigns: %{challenge: nil}} = socket), do: assign(socket, contributions: [], snap: nil)

  defp load(%{assigns: %{challenge: challenge}} = socket) do
    contributions = Savings.list_contributions(challenge)
    assign(socket, contributions: contributions, snap: Plan.snapshot(challenge, contributions, Clock.today()))
  end

  defp notify(socket, message), do: assign(socket, notice: {System.unique_integer([:positive]), message})

  defp reset_deposit_form(%{assigns: %{snap: nil}} = socket), do: socket

  defp reset_deposit_form(socket) do
    week = Enum.at(socket.assigns.snap.weeks, socket.assigns.selected - 1)

    attrs = %{
      "week" => week.week,
      "amount" => if(week.paid < week.target, do: week.target - week.paid, else: nil),
      "deposited_on" => Date.to_iso8601(Clock.today()),
      "idempotency_key" => Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)
    }

    assign(socket, deposit_form: to_form(Savings.change_contribution(%Contribution{}, attrs), as: :deposit))
  end

  # The week always comes from the server-side selection, never from the form,
  # and when editing it stays on the contribution's own week.
  defp deposit_attrs(socket, params) do
    week =
      case socket.assigns.editing do
        nil -> socket.assigns.selected
        id -> Enum.find_value(socket.assigns.contributions, socket.assigns.selected, &(&1.id == id && &1.week))
      end

    params |> Map.take(["amount", "deposited_on", "note", "idempotency_key"]) |> Map.put("week", week)
  end

  defp open_settings(socket) do
    challenge = socket.assigns.challenge || Challenge.new_default()
    assign_settings(assign(socket, settings_open: true), Savings.change_challenge(challenge))
  end

  defp settings_changeset(socket, params) do
    Savings.change_challenge(socket.assigns.challenge || Challenge.new_default(), params)
  end

  defp assign_settings(socket, changeset) do
    preview =
      case Ecto.Changeset.apply_action(changeset, :preview) do
        {:ok, challenge} -> %{projected: Plan.projected_total(challenge), goal: Plan.goal(challenge)}
        {:error, _} -> nil
      end

    assign(socket, settings_form: to_form(changeset, as: :challenge), settings_preview: preview)
  end

  ## Render

  @impl true
  def render(assigns) do
    ~H"""
    <div class="loadbar" aria-hidden="true"></div>
    <main class="app" phx-window-keydown="close_settings" phx-key="escape">
      <div :if={@notice} id={"notice-#{elem(@notice, 0)}"} class="notice" role="status">{elem(@notice, 1)}</div>

      <%= if @snap do %>
        <header class="topbar">
          <div class="title">
            <.link navigate="/" class="back">‹ All goals</.link>
            <p class="eyebrow">{Challenge.category_label(@challenge.category)}</p>
            <h1>{@challenge.name}</h1>
          </div>
          <button class="btn btn-ghost" phx-click="open_settings">Plan</button>
        </header>

        <.hero snap={@snap} />

        <section class="card">
          <div class="section-head">
            <h2>Your 52 weeks</h2>
            <p class="muted">Tap a week to see or add deposits</p>
          </div>
          <.legend />
          <div class="grid" role="list">
            <button
              :for={w <- @snap.weeks}
              role="listitem"
              class={["cell", "is-#{w.status}", @selected == w.week && "is-selected"]}
              style={"--fill: #{w.fill}%"}
              phx-click="select_week"
              phx-value-week={w.week}
              aria-label={"Week #{w.week}, target #{ksh(w.target)}, #{w.status}"}
              aria-pressed={to_string(@selected == w.week)}
            >
              <span class="cell-week">{w.week}</span>
              <span :if={w.status == :completed} class="cell-check" aria-hidden="true">✓</span>
              <span :if={w.status != :completed} class="cell-amt">{num(w.target)}</span>
            </button>
          </div>
        </section>

        <.week_panel
          week={Enum.at(@snap.weeks, @selected - 1)}
          deposits={Enum.filter(@contributions, &(&1.week == @selected))}
          form={@deposit_form}
          editing={@editing}
          today={Clock.today()}
          is_current={@snap.current_week == @selected}
        />

        <.chart snap={@snap} />
        <p class="foot muted">Amounts are in Kenyan shillings (KSh). Your data is saved automatically.</p>
      <% else %>
        <header class="topbar">
          <div class="title">
            <.link :if={@has_goals} navigate="/" class="back">‹ All goals</.link>
            <p class="eyebrow">New goal</p>
            <h1>52-Week Challenge</h1>
          </div>
        </header>
        <section class="card empty">
          <p class="lead">Save a little more each week, and watch it add up.</p>
          <p class="muted">Name your goal, pick the amounts, and start. You can change it any time.</p>
        </section>
      <% end %>

      <%= if @settings_open do %>
        <div class={["backdrop", @challenge == nil && "backdrop-static"]} phx-click="close_settings"></div>
        <section class={["sheet", @challenge == nil && "sheet-inline"]} role="dialog" aria-label="Challenge plan">
          <div class="section-head">
            <h2>{if @challenge, do: "Your plan", else: "Create your goal"}</h2>
            <button :if={@challenge} class="btn btn-ghost" phx-click="close_settings" aria-label="Close">✕</button>
          </div>
          <.settings_form form={@settings_form} preview={@settings_preview} new={@challenge == nil} />
          <div :if={@challenge} class="danger-zone">
            <button :if={!@confirm_delete} type="button" class="btn btn-ghost danger btn-block" phx-click="ask_delete_goal">
              Delete this goal
            </button>
            <button :if={@confirm_delete} type="button" class="btn btn-ghost danger btn-block" phx-click="delete_goal">
              Yes, delete this goal and all its deposits
            </button>
          </div>
        </section>
      <% end %>
    </main>
    """
  end

  defp hero(assigns) do
    assigns =
      assign(assigns,
        circumference: @ring_circumference,
        offset: @ring_circumference * (1 - ring_fraction(assigns.snap)),
        r: @ring_radius
      )

    ~H"""
    <section class={["card hero", @snap.goal_reached? && "is-done"]}>
      <div class="hero-main">
        <div class="ring" role="img" aria-label={"#{@snap.percent} percent of goal saved"}>
          <svg viewBox="0 0 120 120">
            <circle class="ring-track" cx="60" cy="60" r={@r} />
            <circle
              class="ring-bar"
              cx="60"
              cy="60"
              r={@r}
              stroke-dasharray={@circumference}
              style={"stroke-dashoffset: #{Float.round(@offset, 2)}"}
              transform="rotate(-90 60 60)"
            />
          </svg>
          <div class="ring-label">
            <strong>{@snap.percent}%</strong>
            <span>of goal</span>
          </div>
        </div>
        <div class="hero-figures">
          <p class="eyebrow">Total saved</p>
          <p class="big">{ksh(@snap.saved)}</p>
          <p class="muted">of {ksh(@snap.goal)} goal</p>
          <p class="muted"><strong>{ksh(@snap.remaining)}</strong> to go</p>
        </div>
      </div>

      <div :if={@snap.goal_reached?} class="banner">Goal reached. Brilliant work, you did it!</div>

      <div :if={!@snap.goal_reached?} class="next">
        <div>
          <p class="eyebrow">Week {@snap.current_week} of 52</p>
          <%= if @snap.next do %>
            <p class="next-amt">
              Next: <strong>{ksh(@snap.next.amount)}</strong>
              <span class="muted">for week {@snap.next.week}</span>
            </p>
          <% else %>
            <p class="next-amt">All 52 weeks are covered.</p>
          <% end %>
        </div>
        <p :if={@snap.behind > 0} class="behind">{ksh(@snap.behind)} behind plan</p>
      </div>

      <p :if={@snap.saved == 0} class="muted hint">Record your first deposit below to get started.</p>

      <dl class="stats">
        <div><dt>Weeks done</dt><dd>{@snap.completed_weeks}<small> / 52</small></dd></div>
        <div><dt>Weeks left</dt><dd>{@snap.remaining_weeks}</dd></div>
        <div><dt>Still planned</dt><dd>{ksh(@snap.outstanding)}</dd></div>
        <div><dt>Projected final</dt><dd>{ksh(@snap.projected_final)}</dd></div>
      </dl>
    </section>
    """
  end

  defp legend(assigns) do
    ~H"""
    <ul class="legend">
      <li><i class="dot is-completed"></i>Done</li>
      <li><i class="dot is-current"></i>This week</li>
      <li><i class="dot is-missed"></i>Missed</li>
      <li><i class="dot is-upcoming"></i>Upcoming</li>
    </ul>
    """
  end

  defp week_panel(assigns) do
    assigns = assign(assigns, to_go: max(assigns.week.target - assigns.week.paid, 0))

    ~H"""
    <section class="card" id="week-panel">
      <div class="section-head">
        <h2>Week {@week.week}</h2>
        <span class={["pill", "is-#{@week.status}"]}>{status_label(@week.status)}</span>
      </div>

      <dl class="stats stats-3">
        <div><dt>Target</dt><dd>{ksh(@week.target)}</dd></div>
        <div><dt>Saved</dt><dd>{ksh(@week.paid)}</dd></div>
        <div><dt>{if @to_go > 0, do: "To go", else: "Extra"}</dt><dd>{ksh(if @to_go > 0, do: @to_go, else: @week.paid - @week.target)}</dd></div>
      </dl>

      <div class="bar" aria-hidden="true"><div class="bar-fill" style={"width: #{@week.fill}%"}></div></div>

      <ul :if={@deposits != []} class="deposits">
        <li :for={d <- @deposits} class={@editing == d.id && "is-editing"}>
          <div>
            <strong>{ksh(d.amount)}</strong>
            <span class="muted">{Calendar.strftime(d.deposited_on, "%d %b %Y")}<%= if d.note && d.note != "" do %> · {d.note}<% end %></span>
          </div>
          <div class="row-actions">
            <button class="btn btn-ghost btn-sm" phx-click="edit_deposit" phx-value-id={d.id}>Edit</button>
            <button
              class="btn btn-ghost btn-sm danger"
              phx-click="delete_deposit"
              phx-value-id={d.id}
              data-confirm={"Delete this #{ksh(d.amount)} deposit?"}
            >
              Delete
            </button>
          </div>
        </li>
      </ul>
      <p :if={@deposits == []} class="muted empty-line">No deposits for this week yet.</p>

      <button :if={@to_go > 0 && is_nil(@editing)} class="btn btn-primary btn-block" phx-click="pay_week" phx-disable-with="Saving…">
        Save {ksh(@to_go)} now
      </button>

      <.form for={@form} id="deposit-form" class="form" phx-change="validate_deposit" phx-submit="save_deposit">
        <h3>{if @editing, do: "Edit deposit", else: "Add a deposit"}</h3>
        <input type="hidden" name={@form[:idempotency_key].name} value={@form[:idempotency_key].value} />
        <div class="field-row">
          <label class="field">
            <span>Amount (KSh)</span>
            <input type="number" inputmode="numeric" min="1" step="1" name={@form[:amount].name} value={@form[:amount].value} placeholder="e.g. 500" required />
            <small :for={msg <- errors(@form[:amount])} class="error">{msg}</small>
          </label>
          <label class="field">
            <span>Date</span>
            <input type="date" max={Date.to_iso8601(@today)} name={@form[:deposited_on].name} value={@form[:deposited_on].value} required />
            <small :for={msg <- errors(@form[:deposited_on])} class="error">{msg}</small>
          </label>
        </div>
        <label class="field">
          <span>Note (optional)</span>
          <input type="text" maxlength="120" name={@form[:note].name} value={@form[:note].value} placeholder="e.g. Sunday top-up" />
          <small :for={msg <- errors(@form[:note])} class="error">{msg}</small>
        </label>
        <small :for={msg <- errors(@form[:week])} class="error">{msg}</small>
        <div class="form-actions">
          <button type="submit" class="btn btn-primary" phx-disable-with="Saving…">{if @editing, do: "Update deposit", else: "Add deposit"}</button>
          <button :if={@editing} type="button" class="btn btn-ghost" phx-click="cancel_edit">Cancel</button>
        </div>
      </.form>
    </section>
    """
  end

  defp chart(assigns) do
    w = 320
    h = 140
    series = assigns.snap.series
    ymax = Enum.max([assigns.snap.goal, assigns.snap.planned_total, assigns.snap.saved, 1])
    actual = Enum.filter(series, & &1.actual)

    assigns =
      assign(assigns,
        w: w,
        h: h,
        plan_pts: points(series, :plan, w, h, ymax),
        actual_pts: points(actual, :actual, w, h, ymax),
        last: List.last(actual),
        goal_y: y(assigns.snap.goal, h, ymax),
        ymax: ymax
      )

    ~H"""
    <section class="card">
      <div class="section-head">
        <h2>Savings over time</h2>
        <ul class="legend">
          <li><i class="line actual"></i>Actual</li>
          <li><i class="line plan"></i>Plan</li>
        </ul>
      </div>
      <svg class="chart" viewBox={"0 0 #{@w} #{@h + 4}"} role="img" aria-label="Cumulative savings by week, actual versus plan">
        <line class="goal-line" x1="0" x2={@w} y1={@goal_y} y2={@goal_y} />
        <polyline class="plan-line" points={@plan_pts} />
        <polygon :if={@last && @last.actual > 0} class="actual-area" points={"0,#{@h} #{@actual_pts} #{x(@last.week, @w)},#{@h}"} />
        <polyline :if={@last} class="actual-line" points={@actual_pts} />
        <circle :if={@last} class="actual-dot" cx={x(@last.week, @w)} cy={y(@last.actual, @h, @ymax)} r="3.5" />
      </svg>
      <div class="axis"><span>Week 1</span><span>Week 26</span><span>Week 52</span></div>
      <p class="muted chart-note">Dashed line is your goal ({ksh(@snap.goal)}).</p>
    </section>
    """
  end

  defp settings_form(assigns) do
    assigns = assign(assigns, fixed?: assigns.form[:mode].value == "fixed")

    ~H"""
    <.form for={@form} id="settings-form" class="form" phx-change="validate_settings" phx-submit="save_settings">
      <label class="field">
        <span>Name</span>
        <input type="text" name={@form[:name].name} value={@form[:name].value} maxlength="60" required />
        <small :for={msg <- errors(@form[:name])} class="error">{msg}</small>
      </label>

      <label class="field">
        <span>What are you saving for?</span>
        <select name={@form[:category].name}>
          <option :for={{value, label} <- Challenge.categories()} value={value} selected={@form[:category].value == value}>
            {label}
          </option>
        </select>
      </label>

      <fieldset class="seg">
        <legend>Weekly pattern</legend>
        <label class={["seg-opt", !@fixed? && "on"]}>
          <input type="radio" name={@form[:mode].name} value="increasing" checked={!@fixed?} />
          <span>Increasing</span>
          <small>Starts small, grows weekly</small>
        </label>
        <label class={["seg-opt", @fixed? && "on"]}>
          <input type="radio" name={@form[:mode].name} value="fixed" checked={@fixed?} />
          <span>Fixed</span>
          <small>Same amount every week</small>
        </label>
      </fieldset>

      <div class="field-row">
        <label class="field">
          <span>{if @fixed?, do: "Weekly amount (KSh)", else: "Week 1 amount (KSh)"}</span>
          <input type="number" inputmode="numeric" min="1" step="1" name={@form[:start_amount].name} value={@form[:start_amount].value} required />
          <small :for={msg <- errors(@form[:start_amount])} class="error">{msg}</small>
        </label>
        <label :if={!@fixed?} class="field">
          <span>Weekly increase (KSh)</span>
          <input type="number" inputmode="numeric" min="0" step="1" name={@form[:increment].name} value={@form[:increment].value} />
          <small :for={msg <- errors(@form[:increment])} class="error">{msg}</small>
        </label>
      </div>

      <div class="field-row">
        <label class="field">
          <span>Start date</span>
          <input type="date" name={@form[:start_date].name} value={@form[:start_date].value} required />
          <small :for={msg <- errors(@form[:start_date])} class="error">{msg}</small>
        </label>
        <label class="field">
          <span>Goal amount (optional)</span>
          <input type="number" inputmode="numeric" min="1" step="1" name={@form[:target_amount].name} value={@form[:target_amount].value} placeholder="e.g. 150000 for a trip" />
          <small class="muted">Enter a goal and we suggest the weekly amounts.</small>
          <small :for={msg <- errors(@form[:target_amount])} class="error">{msg}</small>
        </label>
      </div>

      <div class="preview" aria-live="polite">
        <%= if @preview do %>
          <span>Plan over 52 weeks</span>
          <strong>{ksh(@preview.projected)}</strong>
          <span :if={@preview.goal != @preview.projected} class="muted">Your goal: {ksh(@preview.goal)}</span>
        <% else %>
          <span class="muted">Fill in the amounts to see your 52-week total.</span>
        <% end %>
      </div>

      <p :if={!@new} class="muted note">Your recorded deposits are kept when you change the plan; week targets are recalculated.</p>

      <button type="submit" class="btn btn-primary btn-block" phx-disable-with="Saving…">
        {if @new, do: "Start my challenge", else: "Save plan"}
      </button>
    </.form>
    """
  end

  ## View helpers

  defp ring_fraction(%{saved: saved, goal: goal}), do: min(saved / max(goal, 1), 1.0)

  defp status_label(:completed), do: "Done"
  defp status_label(:current), do: "This week"
  defp status_label(:missed), do: "Missed"
  defp status_label(:upcoming), do: "Upcoming"

  defp x(week, w), do: fmt((week - 1) / 51 * w)
  defp y(value, h, ymax), do: fmt(h - value / ymax * h)

  defp points(rows, key, w, h, ymax) do
    Enum.map_join(rows, " ", fn row -> "#{x(row.week, w)},#{y(Map.fetch!(row, key), h, ymax)}" end)
  end

  defp fmt(float), do: :erlang.float_to_binary(float * 1.0, decimals: 1)

  defp errors(field), do: Enum.map(field.errors, &translate_error/1)

  defp translate_error({msg, opts}) do
    Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
      opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
    end)
  end
end
