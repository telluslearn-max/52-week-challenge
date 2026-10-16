defmodule SavingsChallengeWeb.HistoryLive do
  @moduledoc "Every deposit and withdrawal across all goals, with a filter for money taken out."
  use SavingsChallengeWeb, :live_view

  import SavingsChallengeWeb.Format

  alias SavingsChallenge.Savings
  alias SavingsChallengeWeb.Layouts

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, page_title: "History", pin_set?: SavingsChallenge.Lock.pin_set?())}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    filter = if params["show"] == "withdrawals", do: :withdrawals, else: :all
    rows = Savings.list_movements(filter)
    out = rows |> Enum.map(& &1.contribution.amount) |> Enum.filter(&(&1 < 0)) |> Enum.sum() |> abs()

    {:noreply, assign(socket, filter: filter, rows: rows, total_out: out, total_in: Enum.sum(for %{contribution: %{amount: a}} <- rows, a > 0, do: a))}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="loadbar" aria-hidden="true"></div>
    <main class="app has-tabbar">
      <header class="topbar">
        <div class="title">
          <.link navigate="/" class="back">‹ All goals</.link>
          <h1>History</h1>
        </div>
      </header>

      <div class="len-toggle" role="group" aria-label="Filter">
        <.link patch="/history" class={["chip", @filter == :all && "on"]}>All</.link>
        <.link patch="/history?show=withdrawals" class={["chip", @filter == :withdrawals && "on"]}>Withdrawals</.link>
      </div>

      <section class="card">
        <dl class="stats stats-3">
          <div :if={@filter == :all}><dt>Put in</dt><dd>{ksh(@total_in)}</dd></div>
          <div><dt>Taken out</dt><dd>{ksh(@total_out)}</dd></div>
          <div><dt>Entries</dt><dd>{length(@rows)}</dd></div>
        </dl>
      </section>

      <section class="card" id="history">
        <p :if={@rows == []} class="muted">{if @filter == :withdrawals, do: "No withdrawals yet.", else: "Nothing recorded yet."}</p>
        <ul :if={@rows != []} class="txns">
          <li :for={r <- @rows}>
            <span class={["tx-ico", r.contribution.amount < 0 && "out"]} aria-hidden="true">{if r.contribution.amount < 0, do: "↓", else: "↑"}</span>
            <div>
              <strong>
                <%= cond do %>
                  <% r.contribution.amount < 0 -> %>{r.contribution.note || "Withdrawal"}
                  <% r.contribution.note not in [nil, ""] -> %>{r.contribution.note}
                  <% true -> %>Goal top up
                <% end %>
              </strong>
              <span class="muted">
                <.link navigate={"/goals/#{r.goal_id}"} class="plain">{r.goal_name}</.link> · {Calendar.strftime(r.contribution.deposited_on, "%d %b %Y")}
                <span :if={r.contribution.debt_id}> · debt payment</span>
              </span>
            </div>
            <strong class={["tx-amt", r.contribution.amount < 0 && "out"]}>{if r.contribution.amount > 0, do: "+"}{ksh(r.contribution.amount)}</strong>
          </li>
        </ul>
      </section>
    </main>
    <Layouts.bottom_nav active={:home} lock_href={if @pin_set?, do: "/lock", else: "/unlock/setup"} />
    """
  end
end
