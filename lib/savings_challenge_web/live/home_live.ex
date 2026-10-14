defmodule SavingsChallengeWeb.HomeLive do
  use SavingsChallengeWeb, :live_view

  import SavingsChallengeWeb.Format

  alias SavingsChallenge.{Challenge, Clock, Plan, Reminders, Savings}
  alias SavingsChallengeWeb.Layouts

  @impl true
  def mount(_params, _session, socket) do
    if Savings.count_challenges() == 0 do
      {:ok, push_navigate(socket, to: "/goals/new")}
    else
      {:ok, socket |> assign(page_title: "My goals", pin_set?: SavingsChallenge.Lock.pin_set?()) |> load()}
    end
  end

  defp load(socket) do
    today = Clock.today()

    goals =
      for challenge <- Savings.list_challenges() do
        %{challenge: challenge, snap: Plan.snapshot(challenge, Savings.current_contributions(challenge), today)}
      end

    # Debts live in their own list: unpaid above, paid below.
    {debts, rest} = Enum.split_with(goals, &(&1.challenge.category == "debt"))
    {unpaid, paid} = Enum.split_with(debts, &is_nil(&1.challenge.completed_at))
    unpaid = Enum.sort_by(unpaid, &{&1.challenge.end_date || ~D[9999-12-31], &1.challenge.id})
    paid = Enum.sort_by(paid, & &1.challenge.completed_at, {:desc, DateTime})

    {active, finished} = Enum.split_with(rest, &is_nil(&1.challenge.completed_at))

    # Bills first, soonest due date first; everything else keeps its order.
    {bills, others} = Enum.split_with(active, &(&1.challenge.kind == "bill"))
    active = Enum.sort_by(bills, & &1.challenge.end_date, Date) ++ others

    assign(socket,
      active: active,
      finished: finished,
      unpaid_debts: unpaid,
      paid_debts: paid,
      owed: unpaid |> Enum.map(&max(&1.snap.goal - &1.snap.saved, 0)) |> Enum.sum(),
      goals: goals,
      today: today,
      total: Enum.sum(Enum.map(goals, & &1.snap.saved)),
      today_target: Reminders.digest(goals, today).total,
      topup_id: topup_goal(active ++ unpaid)
    )
  end

  @impl true
  def handle_event("toggle_debt", %{"id" => id}, socket) do
    case Savings.get_challenge(id) do
      %Challenge{category: "debt", completed_at: nil} = c -> Savings.complete_challenge(c)
      %Challenge{category: "debt"} = c -> Savings.reopen_challenge(c)
      _ -> :ignore
    end

    {:noreply, load(socket)}
  end

  # "Top up" opens the goal that needs money today, else the first active one.
  defp topup_goal(active) do
    pick = Enum.find(active, &(&1.snap.next && &1.snap.next.week == &1.snap.current_week && &1.challenge.kind != "tranche")) || List.first(active)
    pick && pick.challenge.id
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="loadbar" aria-hidden="true"></div>
    <main class="app has-tabbar">
      <section class="wallet" id="wallet" phx-hook="Eye" data-hidden="false">
        <div class="wallet-top">
          <p class="wallet-eyebrow">My savings · {length(@goals)} {if length(@goals) == 1, do: "goal", else: "goals"}</p>
          <button type="button" class="eye" data-eye aria-label="Hide or show amounts" aria-pressed="false">
            <svg viewBox="0 0 24 24" aria-hidden="true">
              <path d="M2 12s3.6-7 10-7 10 7 10 7-3.6 7-10 7S2 12 2 12z" />
              <circle cx="12" cy="12" r="3" />
              <path class="eye-slash" d="M4 4l16 16" />
            </svg>
          </button>
        </div>
        <div class="wallet-figs">
          <div>
            <p class="w-label">Total saved</p>
            <p class="w-num"><span class="amt">{ksh(@total)}</span><span class="amt-mask" aria-hidden="true">••••••</span></p>
          </div>
          <div>
            <p class="w-label">Today's target</p>
            <p class="w-num"><span class="amt">{ksh(@today_target)}</span><span class="amt-mask" aria-hidden="true">••••</span></p>
          </div>
        </div>
        <div class="wallet-actions">
          <.link :if={@topup_id} navigate={"/goals/#{@topup_id}#deposit-form"} class="w-act"><i>+</i><span>Top up</span></.link>
          <.link navigate="/goals/new" class="w-act"><i>◎</i><span>New goal</span></.link>
          <.link navigate="/reminders" class="w-act"><i>🔔</i><span>Reminders</span></.link>
        </div>
      </section>

      <div :if={@active != []} class="section-title"><h2>Your goals</h2></div>

      <a :if={!@pin_set?} href="/unlock/setup" class="card pin-prompt">
        <strong>Protect your savings with a PIN</strong>
        <span class="muted">Lock the app like M-Pesa. Takes 20 seconds.</span>
      </a>

      <section :if={@active != []} class="goals">
        <.goal_card :for={g <- @active} g={g} today={@today} />
      </section>

      <section :if={@unpaid_debts != [] or @paid_debts != []} class="debts" id="debts">
        <div class="section-title">
          <h2>Debts</h2>
          <span class="muted">{length(@unpaid_debts)} unpaid{if @owed > 0, do: " · #{ksh(@owed)} to clear"}</span>
        </div>
        <ul class="debt-list">
          <.debt_row :for={g <- @unpaid_debts} g={g} today={@today} />
        </ul>
        <h3 :if={@paid_debts != []} class="cat-title">Paid</h3>
        <ul :if={@paid_debts != []} class="debt-list">
          <.debt_row :for={g <- @paid_debts} g={g} today={@today} />
        </ul>
      </section>

      <section :if={@finished != []} class="goals">
        <h2 class="cat-title">Completed</h2>
        <.goal_card :for={g <- @finished} g={g} today={@today} />
      </section>

      <p :if={@pin_set?} class="foot"><a href="/unlock/change" class="back">Change PIN</a></p>
    </main>
    <Layouts.bottom_nav active={:home} lock_href={if @pin_set?, do: "/lock", else: "/unlock/setup"} />
    """
  end

  defp time_text(%{challenge: %{completed_at: at}}, _today) when not is_nil(at), do: "Completed"

  defp time_text(%{challenge: %{start_date: start}} = g, today) do
    case Date.diff(start, today) do
      n when n > 0 -> "Starts in #{n} #{if n == 1, do: "day", else: "days"}"
      _ -> time_left(g, today)
    end
  end

  defp time_left(%{challenge: %{kind: kind, end_date: due}}, today) when kind in ["bill", "deadline"] and not is_nil(due) do
    case Date.diff(due, today) do
      0 -> "Due today"
      n when n > 0 -> "#{n} #{if n == 1, do: "day", else: "days"} to go"
      n -> "Overdue by #{abs(n)} #{if n == -1, do: "day", else: "days"}"
    end
  end

  defp time_left(%{snap: snap}, _today), do: "#{snap.remaining_weeks} #{if snap.remaining_weeks == 1, do: unit_word(snap.unit), else: unit_plural(snap.unit)} to go"

  defp debt_row(assigns) do
    assigns = assign(assigns, paid?: not is_nil(assigns.g.challenge.completed_at))

    ~H"""
    <li class={["debt", @paid? && "paid"]}>
      <button
        type="button"
        class={["check", @paid? && "on"]}
        phx-click="toggle_debt"
        phx-value-id={@g.challenge.id}
        aria-label={if @paid?, do: "Mark #{@g.challenge.name} as unpaid", else: "Mark #{@g.challenge.name} as paid"}
      >
        {if @paid?, do: "✓"}
      </button>
      <.link navigate={"/goals/#{@g.challenge.id}"} class="debt-main">
        <strong>{@g.challenge.name}</strong>
        <span class="muted">
          <%= cond do %>
            <% @paid? -> %>Paid {Calendar.strftime(@g.challenge.completed_at, "%d %b %Y")} · {ksh(@g.snap.goal)}
            <% true -> %>{ksh(@g.snap.saved)} of {ksh(@g.snap.goal)} set aside{if @g.challenge.end_date, do: " · " <> due_text(@g.challenge.end_date, @today)}
          <% end %>
        </span>
        <div :if={!@paid?} class="bar" aria-hidden="true"><div class="bar-fill" style={"width: #{@g.snap.percent}%"}></div></div>
      </.link>
    </li>
    """
  end

  defp goal_card(assigns) do
    ~H"""
    <.link navigate={"/goals/#{@g.challenge.id}"} class={["card goal", @g.challenge.completed_at && "done"]}>
      <div class="goal-head">
        <span class="goal-ico" aria-hidden="true">{Challenge.category_icon(@g.challenge.category)}</span>
        <div class="title">
          <h2>{@g.challenge.name}</h2>
          <p class="eyebrow">{Challenge.category_label(@g.challenge.category)}</p>
        </div>
        <span class="goal-chev" aria-hidden="true">›</span>
      </div>
      <div class="goal-amounts"><strong>{ksh(@g.snap.saved)}</strong> <span class="muted">{ksh(@g.snap.goal)}</span></div>
      <div class="bar" aria-hidden="true"><div class="bar-fill" style={"width: #{@g.snap.percent}%"}></div></div>
      <div class="goal-foot">
        <span class="muted">{time_text(@g, @today)}</span>
        <strong class="goal-pct">{if @g.challenge.completed_at, do: "🏆", else: "#{@g.snap.percent}%"}</strong>
      </div>
      <p class="muted goal-detail">
        <%= cond do %>
          <% @g.challenge.completed_at -> %>Completed {Calendar.strftime(@g.challenge.completed_at, "%d %b %Y")}
          <% @g.challenge.kind == "bill" -> %>{due_text(@g.challenge.end_date, @today)} · {if @g.snap.goal_reached?, do: "fully set aside", else: "set aside " <> ksh(@g.snap.next && @g.snap.next.amount || 0) <> " " <> every(@g.snap.unit)}
          <% @g.snap.goal_reached? -> %>Goal reached. Open it to mark it complete
          <% @g.snap.next -> %>{unit_label(@g.snap.unit)} {@g.snap.current_week} of {@g.snap.count} · next {if @g.snap.weeks |> Enum.at(@g.snap.next.week - 1) |> Map.get(:hidden), do: "a surprise", else: ksh(@g.snap.next.amount)}
          <% true -> %>All {@g.snap.count} {unit_plural(@g.snap.unit)} covered
        <% end %>
        <span :if={@g.snap.behind > 0 and !@g.challenge.completed_at} class="behind-inline"> · {ksh(@g.snap.behind)} behind</span>
      </p>
      <p :if={@g.snap.streak > 1 and !@g.challenge.completed_at} class="streak-inline">🔥 {@g.snap.streak}-{unit_word(@g.snap.unit)} streak</p>
      <p :if={@g.challenge.kept_in not in [nil, ""]} class="kept">📍 {@g.challenge.kept_in}</p>
    </.link>
    """
  end
end
