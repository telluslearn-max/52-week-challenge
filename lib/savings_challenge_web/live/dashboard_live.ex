defmodule SavingsChallengeWeb.DashboardLive do
  use SavingsChallengeWeb, :live_view

  import SavingsChallengeWeb.Format

  alias SavingsChallenge.{Badges, Challenge, Clock, Contribution, Plan, Savings}

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
          |> assign(challenge: challenge, editing: nil, notice: nil, confirm_delete: false, confirm_paid: false)
          |> assign(has_goals: Savings.count_challenges() > 0)
          |> assign(settings_open: false, settings_form: nil, settings_preview: nil)
          |> assign(new_category: nil, new_plan: nil, picking: false)
          |> load()

        socket =
          if challenge do
            socket |> assign(selected: socket.assigns.snap.current_week) |> reset_deposit_form()
          else
            category = if Challenge.valid_category?(params["category"]), do: params["category"]
            plan = if Challenge.valid_plan?(params["plan"]), do: params["plan"]

            socket
            |> assign(selected: 1, deposit_form: nil, new_category: category, new_plan: plan)
            |> assign(picking: is_nil(category) and is_nil(plan))
            |> open_settings()
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
      {w, ""} when w >= 1 and w <= socket.assigns.snap.count ->
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
    unit = unit_label(socket.assigns.snap.unit)

    attrs = %{
      "week" => week.week,
      "amount" => max(week.target - week.paid, 0),
      "deposited_on" => Date.to_iso8601(Clock.today()),
      "idempotency_key" => socket.assigns.deposit_form[:idempotency_key].value
    }

    case Savings.create_contribution(socket.assigns.challenge, attrs) do
      {:ok, _} -> {:noreply, socket |> load() |> reset_deposit_form() |> notify("#{unit} #{week.week} saved")}
      {:error, _} -> {:noreply, notify(socket, "Nothing left to save for this #{unit_word(socket.assigns.snap.unit)}")}
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

  def handle_event("complete_goal", _params, %{assigns: %{challenge: %Challenge{kind: kind} = challenge, snap: %{goal_reached?: true}}} = socket) when kind != "bill" do
    {:ok, challenge} = Savings.complete_challenge(challenge)
    {:noreply, socket |> assign(challenge: challenge) |> notify("Goal completed. Well done!")}
  end

  def handle_event("complete_goal", _params, socket), do: {:noreply, socket}

  def handle_event("reopen_goal", _params, %{assigns: %{challenge: %Challenge{} = challenge}} = socket) do
    {:ok, challenge} = Savings.reopen_challenge(challenge)
    {:noreply, socket |> assign(challenge: challenge) |> notify("Goal reopened")}
  end

  def handle_event("ask_paid", _params, socket), do: {:noreply, assign(socket, confirm_paid: true)}

  def handle_event("mark_paid", _params, %{assigns: %{challenge: %Challenge{kind: "bill"} = challenge}} = socket) do
    {:ok, updated} = Savings.mark_bill_paid(challenge, Clock.today())

    socket =
      socket
      |> assign(challenge: updated, confirm_paid: false, editing: nil)
      |> load()
      |> then(fn s -> assign(s, selected: s.assigns.snap.current_week) end)
      |> reset_deposit_form()

    message =
      if updated.completed_at,
        do: "Bill paid. All done!",
        else: "Paid. Next one is due #{Calendar.strftime(updated.end_date, "%d %b")}#{carried_text(socket)}"

    {:noreply, notify(socket, message)}
  end

  def handle_event("mark_paid", _params, socket), do: {:noreply, socket}

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
  defp maybe_fit_plan(%{"plan" => plan} = params, ["challenge", "target_amount"])
       when plan in ["weekly_increasing", "weekly_fixed"] do
    case Integer.parse(String.trim(params["target_amount"] || "")) do
      {goal, ""} when goal > 0 ->
        if plan == "weekly_fixed" do
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

  defp load(%{assigns: %{challenge: nil}} = socket), do: assign(socket, contributions: [], snap: nil, payments: [])

  defp load(%{assigns: %{challenge: challenge}} = socket) do
    contributions = Savings.list_contributions(challenge)
    snap = Plan.snapshot(challenge, contributions, Clock.today())
    badges = Badges.all(snap)
    earned = for b <- badges, b.earned?, do: b.key

    # Badges that were not earned before this change (nothing is "new" on first load).
    unlocked =
      case socket.assigns[:earned] do
        nil -> []
        before -> Enum.filter(badges, &(&1.earned? and &1.key not in before))
      end

    payments = if challenge.kind == "bill", do: Savings.list_bill_payments(challenge), else: []

    assign(socket, contributions: contributions, snap: snap, badges: badges, earned: earned, unlocked: unlocked, payments: payments)
  end

  # After a new bill cycle starts, the only deposit it can hold is a carried-over surplus.
  defp carried_text(%{assigns: %{snap: %{saved: saved}}}) when saved > 0, do: ". #{ksh(saved)} carried over"
  defp carried_text(_socket), do: ""

  defp notify(socket, message) do
    message =
      case socket.assigns[:unlocked] do
        [badge | _] -> "#{message} · Badge unlocked: #{badge.icon} #{badge.label}"
        _ -> message
      end

    assign(socket, notice: {System.unique_integer([:positive]), message}, unlocked: [])
  end

  defp reset_deposit_form(%{assigns: %{snap: nil}} = socket), do: socket

  defp reset_deposit_form(socket) do
    week = Enum.at(socket.assigns.snap.weeks, socket.assigns.selected - 1)

    attrs = %{
      "week" => week.week,
      "amount" => if(week.paid < week.target and not week.hidden, do: week.target - week.paid, else: nil),
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
    assign_settings(assign(socket, settings_open: true), Savings.change_challenge(current_or_new(socket)))
  end

  defp settings_changeset(socket, params) do
    Savings.change_challenge(current_or_new(socket), params)
  end

  defp current_or_new(%{assigns: %{challenge: %Challenge{} = challenge}}), do: Challenge.with_plan(challenge)

  defp current_or_new(%{assigns: %{new_category: category, new_plan: plan}}) do
    base = %{Challenge.new_default() | plan: plan || "weekly_increasing", start_amount: default_amount(plan)}

    cond do
      category -> %{base | category: category, name: Challenge.category_label(category)}
      plan == "bill" -> %{base | category: "bills", name: "Bill", frequency: "day"}
      plan -> %{base | name: Challenge.plan_label(plan)}
      true -> base
    end
  end

  defp default_amount(plan) when plan in ["daily", "envelope"], do: 100
  defp default_amount(_plan), do: 50

  defp assign_settings(socket, changeset) do
    preview =
      case Ecto.Changeset.apply_action(changeset, :preview) do
        {:ok, challenge} ->
          %{
            projected: Plan.projected_total(challenge),
            goal: Plan.goal(challenge),
            periods: Plan.periods(challenge),
            unit: Plan.unit(challenge),
            kind: Plan.kind(challenge),
            per: challenge.start_amount
          }
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
            <p class="eyebrow">{Challenge.category_icon(@challenge.category)} {Challenge.category_label(@challenge.category)}</p>
            <h1>{@challenge.name}</h1>
          </div>
          <button class="btn btn-ghost" phx-click="open_settings">Plan</button>
        </header>

        <.hero snap={@snap} challenge={@challenge} confirm_paid={@confirm_paid} kept_in={if @challenge.kept_in not in [nil, ""], do: @challenge.kept_in} />

        <section class="card">
          <div class="section-head">
            <h2>Badges</h2>
            <p class="muted">{Enum.count(@badges, & &1.earned?)} of {length(@badges)} earned</p>
          </div>
          <ul class="badges">
            <li :for={b <- @badges} class={["badge", b.earned? && "on"]} title={b.hint}>
              <span class="b-icon" aria-hidden="true">{b.icon}</span>
              <span class="b-label">{b.label}</span>
              <small :if={!b.earned?}>{b.hint}</small>
            </li>
          </ul>
        </section>

        <section class="card">
          <div class="section-head">
            <h2>Your {@snap.count} {unit_plural(@snap.unit)}</h2>
            <p class="muted">Tap a {unit_word(@snap.unit)} to see or add deposits</p>
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
              aria-label={"#{unit_label(@snap.unit)} #{w.week}, #{if w.hidden, do: "target hidden", else: "target " <> ksh(w.target)}, #{w.status}"}
              aria-pressed={to_string(@selected == w.week)}
            >
              <span class="cell-week">{w.week}</span>
              <span :if={w.status == :completed} class="cell-check" aria-hidden="true">✓</span>
              <span :if={w.status != :completed} class="cell-amt">{if w.hidden, do: "?", else: num(w.target)}</span>
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
          unit={@snap.unit}
          starts={Plan.period_start(@challenge, @selected)}
        />

        <section :if={@payments != []} class="card">
          <div class="section-head">
            <h2>Payment history</h2>
            <p class="muted">{length(@payments)} paid</p>
          </div>
          <ul class="deposits">
            <li :for={p <- @payments}>
              <div>
                <strong>{ksh(p.amount_due)}</strong>
                <span class="muted">Paid {Calendar.strftime(p.paid_on, "%d %b %Y")} · due {Calendar.strftime(p.due_date, "%d %b")} · you had set aside {ksh(p.saved)}</span>
              </div>
            </li>
          </ul>
        </section>

        <.chart snap={@snap} />
        <p class="foot muted">Amounts are in Kenyan shillings (KSh). Your data is saved automatically.</p>
      <% else %>
        <header class="topbar">
          <div class="title">
            <.link :if={@picking && @has_goals} navigate="/" class="back">‹ All goals</.link>
            <.link :if={!@picking} navigate="/goals/new" class="back">‹ Change category</.link>
            <p class="eyebrow">New goal</p>
            <h1>{if @picking, do: "What are you saving for?", else: "Set up your goal"}</h1>
          </div>
        </header>

        <%= if @picking do %>
          <p class="muted">Choose a challenge, or pick what you are saving for. You can change the plan on the next step.</p>
          <section class="cat-group">
            <h2 class="cat-title">Challenges</h2>
            <div class="cat-grid">
              <.link :for={{plan, label, icon} <- Challenge.challenge_tiles()} navigate={"/goals/new?plan=#{plan}"} class="cat cat-g-challenge">
                <span class="cat-icon" aria-hidden="true">{icon}</span>
                <span class="cat-label">{label}</span>
              </.link>
            </div>
          </section>
          <section :for={{group, items} <- Challenge.category_groups()} class="cat-group">
            <h2 class="cat-title">{group}</h2>
            <div class="cat-grid">
              <.link :for={{value, label, icon} <- items} navigate={"/goals/new?category=#{value}"} class={["cat", "cat-g-#{String.downcase(group)}"]}>
                <span class="cat-icon" aria-hidden="true">{icon}</span>
                <span class="cat-label">{label}</span>
              </.link>
            </div>
          </section>
        <% end %>
      <% end %>

      <%= if @settings_open && !@picking do %>
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
          <p :if={@kept_in} class="kept">📍 Kept in {@kept_in}</p>
        </div>
      </div>

      <div :if={@snap.goal_reached? and @challenge.kind != "bill"} class="banner">
        <div :if={!@challenge.completed_at} class="confetti" aria-hidden="true"><i :for={n <- 1..14} style={"--n: #{n}"}></i></div>
        <p class="banner-title">{if @challenge.completed_at, do: "Goal completed", else: "Goal reached. Brilliant work!"}</p>
        <p :if={@challenge.completed_at} class="banner-sub">Completed on {Calendar.strftime(@challenge.completed_at, "%d %b %Y")}</p>
        <button :if={!@challenge.completed_at} class="btn btn-light" phx-click="complete_goal">Mark as complete</button>
        <button :if={@challenge.completed_at} class="btn btn-light" phx-click="reopen_goal">Reopen goal</button>
      </div>

      <div :if={!@snap.goal_reached?} class="next">
        <div>
          <p class="eyebrow">{unit_label(@snap.unit)} {@snap.current_week} of {@snap.count}</p>
          <%= if @snap.next do %>
            <p class="next-amt">
              Next: <strong>{ksh(@snap.next.amount)}</strong>
              <span class="muted">for {unit_word(@snap.unit)} {@snap.next.week}</span>
            </p>
          <% else %>
            <p class="next-amt">All {@snap.count} {unit_plural(@snap.unit)} are covered.</p>
          <% end %>
        </div>
        <p :if={@snap.behind > 0} class="behind">{ksh(@snap.behind)} behind plan</p>
      </div>

      <div :if={@challenge.kind == "bill" and @challenge.completed_at} class="banner">
        <p class="banner-title">Bill paid</p>
        <p class="banner-sub">Completed on {Calendar.strftime(@challenge.completed_at, "%d %b %Y")}</p>
      </div>

      <div :if={@challenge.kind == "bill" and is_nil(@challenge.completed_at)} class="bill-box">
        <div>
          <p class="eyebrow">Due {Calendar.strftime(@challenge.end_date, "%a %d %b %Y")}</p>
          <p class={["due", Date.compare(@challenge.end_date, Clock.today()) == :lt && "overdue"]}>
            {due_text(@challenge.end_date, Clock.today())}
            <span class="muted">· {recurrence_label(@challenge.recurrence)}</span>
          </p>
          <p :if={@snap.goal_reached?} class="ok">Fully set aside ✓</p>
        </div>
        <button class={["btn", @confirm_paid && "btn-primary", !@confirm_paid && "btn-ghost"]} phx-click={if @confirm_paid, do: "mark_paid", else: "ask_paid"}>
          {if @confirm_paid, do: "Confirm: I paid it", else: "Mark as paid"}
        </button>
      </div>

      <p :if={@snap.streak > 0 and !@snap.goal_reached?} class="streak">
        🔥 {@snap.streak}-{unit_word(@snap.unit)} streak <span class="muted">· best {@snap.best_streak}</span>
      </p>

      <p :if={@snap.saved == 0} class="muted hint">Record your first deposit below to get started.</p>

      <dl class="stats">
        <div><dt>{unit_plural(@snap.unit) |> String.capitalize()} done</dt><dd>{@snap.completed_weeks}<small> / {@snap.count}</small></dd></div>
        <div><dt>{unit_plural(@snap.unit) |> String.capitalize()} left</dt><dd>{@snap.remaining_weeks}</dd></div>
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
      <li><i class="dot is-current"></i>Now</li>
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
        <h2>{unit_label(@unit)} {@week.week}</h2>
        <span class={["pill", "is-#{@week.status}"]}>{status_label(@week.status)}</span>
      </div>
      <p class="muted when">{if @unit == "month", do: "Starts", else: "On"} {Calendar.strftime(@starts, "%a %d %b %Y")}</p>

      <dl class="stats stats-3">
        <div><dt>Target</dt><dd>{if @week.hidden, do: "A surprise", else: ksh(@week.target)}</dd></div>
        <div><dt>Saved</dt><dd>{ksh(@week.paid)}</dd></div>
        <div><dt>{if @to_go > 0, do: "To go", else: "Extra"}</dt><dd>{ksh(if @to_go > 0, do: @to_go, else: @week.paid - @week.target)}</dd></div>
      </dl>

      <p :if={@week.hidden} class="muted">This {unit_word(@unit)}'s amount is revealed when it starts.</p>
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
      <p :if={@deposits == []} class="muted empty-line">No deposits for this {unit_word(@unit)} yet.</p>

      <button :if={@to_go > 0 && is_nil(@editing) && !@week.hidden} class="btn btn-primary btn-block" phx-click="pay_week" phx-disable-with="Saving…">
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
    count = assigns.snap.count
    ymax = Enum.max([assigns.snap.goal, assigns.snap.planned_total, assigns.snap.saved, 1])
    actual = Enum.filter(series, & &1.actual)

    assigns =
      assign(assigns,
        w: w,
        h: h,
        count: count,
        plan_pts: points(series, :plan, w, h, ymax, count),
        actual_pts: points(actual, :actual, w, h, ymax, count),
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
      <svg class="chart" viewBox={"0 0 #{@w} #{@h + 4}"} role="img" aria-label="Cumulative savings over time, actual versus plan">
        <line class="goal-line" x1="0" x2={@w} y1={@goal_y} y2={@goal_y} />
        <polyline class="plan-line" points={@plan_pts} />
        <polygon :if={@last && @last.actual > 0} class="actual-area" points={"0,#{@h} #{@actual_pts} #{x(@last.week, @w, @count)},#{@h}"} />
        <polyline :if={@last} class="actual-line" points={@actual_pts} />
        <circle :if={@last} class="actual-dot" cx={x(@last.week, @w, @count)} cy={y(@last.actual, @h, @ymax)} r="3.5" />
      </svg>
      <div class="axis"><span>{unit_label(@snap.unit)} 1</span><span>{unit_label(@snap.unit)} {div(@count + 1, 2)}</span><span>{unit_label(@snap.unit)} {@count}</span></div>
      <p class="muted chart-note">Dashed line is your goal ({ksh(@snap.goal)}).</p>
    </section>
    """
  end

  defp settings_form(assigns) do
    plan = assigns.form[:plan].value || "weekly_increasing"
    frequency = assigns.form[:frequency].value || "week"

    assigns =
      assign(assigns,
        plan: plan,
        frequency: frequency,
        weekly?: plan in ["weekly_increasing", "weekly_fixed"],
        amount_label:
          case plan do
            "weekly_increasing" -> "Week 1 amount (KSh)"
            "weekly_fixed" -> "Weekly amount (KSh)"
            "daily" -> "Daily amount (KSh)"
            "envelope" -> "Base amount (KSh)"
            _ -> nil
          end
      )

    ~H"""
    <.form for={@form} id="settings-form" class="form" phx-change="validate_settings" phx-submit="save_settings">
      <label class="field">
        <span>Name</span>
        <input type="text" name={@form[:name].name} value={@form[:name].value} maxlength="60" required />
        <small :for={msg <- errors(@form[:name])} class="error">{msg}</small>
      </label>

      <label class="field">
        <span>Where is this kept? (optional)</span>
        <input type="text" name={@form[:kept_in].name} value={@form[:kept_in].value} maxlength="200" placeholder="e.g. M-Shwari, Sacco, envelope in the drawer" />
        <small class="muted">A reminder for yourself. Don't type account numbers or passwords.</small>
        <small :for={msg <- errors(@form[:kept_in])} class="error">{msg}</small>
      </label>

      <%= if @new do %>
        <input type="hidden" name={@form[:category].name} value={@form[:category].value} />
        <p class="chosen">
          <span aria-hidden="true">{Challenge.category_icon(@form[:category].value)}</span>
          <strong>{Challenge.category_label(@form[:category].value)}</strong>
        </p>
      <% else %>
        <label class="field">
          <span>What are you saving for?</span>
          <select name={@form[:category].name}>
            <optgroup :for={{group, items} <- Challenge.category_groups()} label={group}>
              <option :for={{value, label, icon} <- items} value={value} selected={@form[:category].value == value}>
                {icon} {label}
              </option>
            </optgroup>
          </select>
        </label>
      <% end %>

      <fieldset class="plans">
        <legend>How do you want to save?</legend>
        <label :for={{value, title, desc} <- Challenge.plans()} class={["plan-opt", @plan == value && "on"]}>
          <input type="radio" name={@form[:plan].name} value={value} checked={@plan == value} />
          <span class="plan-title">{title}</span>
          <small>{desc}</small>
        </label>
        <small :for={msg <- errors(@form[:plan])} class="error">{msg}</small>
      </fieldset>

      <%= if @plan in ["deadline", "bill"] do %>
        <label class="field">
          <span>{if @plan == "bill", do: "Amount due (KSh)", else: "How much do you want to save? (KSh)"}</span>
          <input type="number" inputmode="numeric" min="1" step="1" name={@form[:target_amount].name} value={@form[:target_amount].value} placeholder="e.g. 150000" />
          <small :for={msg <- errors(@form[:target_amount])} class="error">{msg}</small>
        </label>
        <div class="field-row">
          <label class="field">
            <span>{if @plan == "bill", do: "Next due date", else: "When do you want to reach it?"}</span>
            <input type="date" name={@form[:end_date].name} value={@form[:end_date].value} />
            <small :for={msg <- errors(@form[:end_date])} class="error">{msg}</small>
          </label>
          <label class="field">
            <span>{if @plan == "bill", do: "Set aside", else: "How often will you save?"}</span>
            <select name={@form[:frequency].name}>
              <option :for={{value, label} <- (if @plan == "bill", do: [{"day", "Daily"}, {"week", "Weekly"}], else: [{"day", "Daily"}, {"week", "Weekly"}, {"month", "Monthly"}])} value={value} selected={@frequency == value}>
                {label}
              </option>
            </select>
            <small :for={msg <- errors(@form[:frequency])} class="error">{msg}</small>
          </label>
        </div>
        <label :if={@plan == "bill"} class="field">
          <span>Does it repeat?</span>
          <select name={@form[:recurrence].name}>
            <option :for={{value, label} <- Challenge.recurrences()} value={value} selected={@form[:recurrence].value == value}>{label}</option>
          </select>
          <small class="muted">After you mark it paid, the next cycle starts automatically.</small>
        </label>
      <% else %>
        <div class="field-row">
          <label class="field">
            <span>{@amount_label}</span>
            <input type="number" inputmode="numeric" min="1" step="1" name={@form[:start_amount].name} value={@form[:start_amount].value} required />
            <small :if={@plan == "envelope"} class="muted">Each week you save this × a number from 1 to 12.</small>
            <small :for={msg <- errors(@form[:start_amount])} class="error">{msg}</small>
          </label>
          <label :if={@plan == "weekly_increasing"} class="field">
            <span>Weekly increase (KSh)</span>
            <input type="number" inputmode="numeric" min="0" step="1" name={@form[:increment].name} value={@form[:increment].value} />
            <small :for={msg <- errors(@form[:increment])} class="error">{msg}</small>
          </label>
        </div>
      <% end %>

      <div class="field-row">
        <label class="field">
          <span>Start date</span>
          <input type="date" name={@form[:start_date].name} value={@form[:start_date].value} required />
          <small :for={msg <- errors(@form[:start_date])} class="error">{msg}</small>
        </label>
        <label :if={@weekly?} class="field">
          <span>Goal amount (optional)</span>
          <input type="number" inputmode="numeric" min="1" step="1" name={@form[:target_amount].name} value={@form[:target_amount].value} placeholder="e.g. 150000 for a trip" />
          <small class="muted">Enter a goal and we suggest the weekly amounts.</small>
          <small :for={msg <- errors(@form[:target_amount])} class="error">{msg}</small>
        </label>
      </div>

      <div class="preview" aria-live="polite">
        <%= cond do %>
          <% is_nil(@preview) -> %>
            <span class="muted">Fill in the details to see your plan.</span>
          <% @preview.kind == "envelope" -> %>
            <span>12 envelopes, you will save</span>
            <strong>{ksh(@preview.projected)}</strong>
          <% @preview.kind == "bill" -> %>
            <span>Set aside <strong class="inline">{ksh(@preview.per)}</strong> {every(@preview.unit)} for {@preview.periods} {unit_plural(@preview.unit)}</span>
            <strong>{ksh(@preview.goal)}</strong>
            <span class="muted">covers this bill when it is due</span>
          <% @preview.kind in ["daily", "deadline"] -> %>
            <span>Save <strong class="inline">{ksh(@preview.per)}</strong> {every(@preview.unit)} for {@preview.periods} {unit_plural(@preview.unit)}</span>
            <strong>{ksh(@preview.projected)}</strong>
            <span :if={@preview.goal != @preview.projected} class="muted">Your goal: {ksh(@preview.goal)}</span>
          <% true -> %>
            <span>Plan over 52 weeks</span>
            <strong>{ksh(@preview.projected)}</strong>
            <span :if={@preview.goal != @preview.projected} class="muted">Your goal: {ksh(@preview.goal)}</span>
        <% end %>
      </div>

      <p :if={!@new} class="muted note">Your recorded deposits are kept when you change the plan; targets are recalculated.</p>

      <button type="submit" class="btn btn-primary btn-block" phx-disable-with="Saving…">
        {if @new, do: "Start my challenge", else: "Save plan"}
      </button>
    </.form>
    """
  end

  ## View helpers

  defp ring_fraction(%{saved: saved, goal: goal}), do: min(saved / max(goal, 1), 1.0)

  defp status_label(:completed), do: "Done"
  defp status_label(:current), do: "Now"
  defp status_label(:missed), do: "Missed"
  defp status_label(:upcoming), do: "Upcoming"

  defp x(week, w, count), do: fmt((week - 1) / max(count - 1, 1) * w)
  defp y(value, h, ymax), do: fmt(h - value / ymax * h)

  defp points(rows, key, w, h, ymax, count) do
    Enum.map_join(rows, " ", fn row -> "#{x(row.week, w, count)},#{y(Map.fetch!(row, key), h, ymax)}" end)
  end

  defp fmt(float), do: :erlang.float_to_binary(float * 1.0, decimals: 1)

  defp errors(field), do: Enum.map(field.errors, &translate_error/1)

  defp translate_error({msg, opts}) do
    Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
      opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
    end)
  end
end
