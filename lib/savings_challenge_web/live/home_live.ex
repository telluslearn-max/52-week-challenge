defmodule SavingsChallengeWeb.HomeLive do
  use SavingsChallengeWeb, :live_view

  import SavingsChallengeWeb.Format

  alias SavingsChallenge.{Challenge, Clock, Plan, Savings}

  @impl true
  def mount(_params, _session, socket) do
    today = Clock.today()

    goals =
      for challenge <- Savings.list_challenges() do
        %{challenge: challenge, snap: Plan.snapshot(challenge, Savings.current_contributions(challenge), today)}
      end

    if goals == [] do
      {:ok, push_navigate(socket, to: "/goals/new")}
    else
      {active, finished} = Enum.split_with(goals, &is_nil(&1.challenge.completed_at))

      # Bills first, soonest due date first; everything else keeps its order.
      {bills, others} = Enum.split_with(active, &(&1.challenge.kind == "bill"))
      active = Enum.sort_by(bills, & &1.challenge.end_date, Date) ++ others

      {:ok,
       assign(socket,
         page_title: "My goals",
         active: active,
         finished: finished,
         goals: goals,
         today: today,
         pin_set?: SavingsChallenge.Lock.pin_set?(),
         total: Enum.sum(Enum.map(goals, & &1.snap.saved))
       )}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="loadbar" aria-hidden="true"></div>
    <main class="app">
      <header class="topbar">
        <div class="title">
          <p class="eyebrow">Total saved across {length(@goals)} {if length(@goals) == 1, do: "goal", else: "goals"}</p>
          <h1>{ksh(@total)}</h1>
        </div>
        <div class="top-actions">
          <a :if={@pin_set?} href="/lock" class="btn btn-ghost" aria-label="Lock the app">🔒 Lock</a>
          <.link navigate="/goals/new" class="btn btn-primary">New goal</.link>
        </div>
      </header>

      <a :if={!@pin_set?} href="/unlock/setup" class="card pin-prompt">
        <strong>Protect your savings with a PIN</strong>
        <span class="muted">Lock the app like M-Pesa. Takes 20 seconds.</span>
      </a>

      <section :if={@active != []} class="goals">
        <.goal_card :for={g <- @active} g={g} today={@today} />
      </section>

      <section :if={@finished != []} class="goals">
        <h2 class="cat-title">Completed</h2>
        <.goal_card :for={g <- @finished} g={g} today={@today} />
      </section>

      <p :if={@pin_set?} class="foot"><a href="/unlock/change" class="back">Change PIN</a></p>
    </main>
    """
  end

  defp goal_card(assigns) do
    ~H"""
    <.link navigate={"/goals/#{@g.challenge.id}"} class={["card goal", @g.challenge.completed_at && "done"]}>
      <div class="goal-head">
        <div class="title">
          <p class="eyebrow">{Challenge.category_icon(@g.challenge.category)} {Challenge.category_label(@g.challenge.category)}</p>
          <h2>{@g.challenge.name}</h2>
        </div>
        <strong class="goal-pct">{if @g.challenge.completed_at, do: "🏆", else: "#{@g.snap.percent}%"}</strong>
      </div>
      <div class="bar" aria-hidden="true"><div class="bar-fill" style={"width: #{@g.snap.percent}%"}></div></div>
      <p class="goal-amounts"><strong>{ksh(@g.snap.saved)}</strong> <span class="muted">of {ksh(@g.snap.goal)}</span></p>
      <p class="muted">
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
