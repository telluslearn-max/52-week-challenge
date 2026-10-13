defmodule SavingsChallengeWeb.HomeLive do
  use SavingsChallengeWeb, :live_view

  import SavingsChallengeWeb.Format

  alias SavingsChallenge.{Challenge, Clock, Plan, Savings}

  @impl true
  def mount(_params, _session, socket) do
    today = Clock.today()

    goals =
      for challenge <- Savings.list_challenges() do
        %{challenge: challenge, snap: Plan.snapshot(challenge, challenge.contributions, today)}
      end

    if goals == [] do
      {:ok, push_navigate(socket, to: "/goals/new")}
    else
      {:ok, assign(socket, page_title: "My goals", goals: goals, total: Enum.sum(Enum.map(goals, & &1.snap.saved)))}
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
        <.link navigate="/goals/new" class="btn btn-primary">New goal</.link>
      </header>

      <section class="goals">
        <.link :for={g <- @goals} navigate={"/goals/#{g.challenge.id}"} class="card goal">
          <div class="goal-head">
            <div class="title">
              <p class="eyebrow">{Challenge.category_label(g.challenge.category)}</p>
              <h2>{g.challenge.name}</h2>
            </div>
            <strong class="goal-pct">{g.snap.percent}%</strong>
          </div>
          <div class="bar" aria-hidden="true"><div class="bar-fill" style={"width: #{g.snap.percent}%"}></div></div>
          <p class="goal-amounts"><strong>{ksh(g.snap.saved)}</strong> <span class="muted">of {ksh(g.snap.goal)}</span></p>
          <p class="muted">
            <%= cond do %>
              <% g.snap.goal_reached? -> %>Goal reached
              <% g.snap.next -> %>Week {g.snap.current_week} of 52 · next {ksh(g.snap.next.amount)}
              <% true -> %>All 52 weeks covered
            <% end %>
            <span :if={g.snap.behind > 0} class="behind-inline"> · {ksh(g.snap.behind)} behind</span>
          </p>
        </.link>
      </section>
    </main>
    """
  end
end
