defmodule SavingsChallengeWeb.HomeLive do
  use SavingsChallengeWeb, :live_view

  import SavingsChallengeWeb.Format

  alias SavingsChallenge.{Challenge, Clock, Debt, Plan, Reminders, Savings}
  alias SavingsChallengeWeb.Layouts

  @impl true
  def mount(_params, _session, socket) do
    if Savings.count_challenges() == 0 and Savings.list_debts() == [] do
      {:ok, push_navigate(socket, to: "/goals/new")}
    else
      {:ok, socket |> assign(page_title: "My goals", pin_set?: SavingsChallenge.Lock.pin_set?(), paying: nil, notice: nil) |> load()}
    end
  end

  defp load(socket) do
    today = Clock.today()

    goals =
      for challenge <- Savings.list_challenges() do
        %{challenge: challenge, snap: Plan.snapshot(challenge, Savings.current_contributions(challenge), today)}
      end

    {active, finished} = Enum.split_with(goals, &is_nil(&1.challenge.completed_at))

    # Bills first, soonest due date first; everything else keeps its order.
    {bills, others} = Enum.split_with(active, &(&1.challenge.kind == "bill"))
    active = Enum.sort_by(bills, & &1.challenge.end_date, Date) ++ others

    debts = Savings.list_debts()
    {unpaid, paid} = Enum.split_with(debts, &(not Debt.paid?(&1)))

    # Pools money can be paid out of: open 52-tranche goals and what they hold.
    pools = for g <- active, g.challenge.kind == "tranche", do: %{id: g.challenge.id, name: g.challenge.name, balance: g.snap.saved}

    assign(socket,
      active: active,
      finished: finished,
      goals: goals,
      today: today,
      total: Enum.sum(Enum.map(goals, & &1.snap.saved)),
      today_target: Reminders.digest(goals, today).total,
      topup_id: topup_goal(active),
      unpaid_debts: unpaid,
      paid_debts: Enum.sort_by(paid, & &1.paid_on, {:desc, Date}),
      owed: unpaid |> Enum.map(&Debt.remaining/1) |> Enum.sum(),
      pools: pools
    )
  end

  defp notify(socket, message), do: assign(socket, notice: {System.unique_integer([:positive]), message})

  defp parse_int(value) do
    case Integer.parse(String.trim(to_string(value))) do
      {n, ""} -> n
      _ -> nil
    end
  end

  @impl true
  def handle_event("add_debt", %{"debt" => params}, socket) do
    case Savings.create_debt(params) do
      {:ok, _} ->
        {:noreply, socket |> load() |> notify("Debt added")}

      {:error, %Ecto.Changeset{} = cs} ->
        {field, [msg | _]} = cs |> Ecto.Changeset.traverse_errors(fn {m, _} -> m end) |> Enum.at(0)
        {:noreply, notify(socket, "Could not add: #{field} #{msg}")}
    end
  end

  def handle_event("ask_pay", %{"id" => id}, socket), do: {:noreply, assign(socket, paying: parse_int(id))}
  def handle_event("cancel_pay", _params, socket), do: {:noreply, assign(socket, paying: nil)}

  def handle_event("pay_debt", %{"debt_id" => id, "amount" => amount, "pool" => pool}, socket) do
    pool_id = if pool == "", do: nil, else: parse_int(pool)

    case Savings.pay_debt(parse_int(id), parse_int(amount), pool_id, Clock.today()) do
      {:ok, debt} ->
        message = if Debt.paid?(debt), do: "#{debt.name} paid", else: "Part payment saved. #{ksh(Debt.remaining(debt))} left"
        {:noreply, socket |> assign(paying: nil) |> load() |> notify(message)}

      {:error, {:insufficient, balance}} ->
        {:noreply, notify(socket, "The pool only has #{ksh(balance)}")}

      {:error, :too_much} ->
        {:noreply, notify(socket, "That is more than is still owed")}

      {:error, _} ->
        {:noreply, notify(socket, "Could not record that payment")}
    end
  end

  def handle_event("undo_debt", %{"id" => id}, socket) do
    Savings.undo_debt(parse_int(id))
    {:noreply, socket |> load() |> notify("Payment reversed. Pool money put back")}
  end

  def handle_event("remove_debt", %{"id" => id}, socket) do
    case Savings.delete_debt(parse_int(id)) do
      {:ok, _} -> {:noreply, socket |> load() |> notify("Debt removed")}
      {:error, _} -> {:noreply, notify(socket, "Reverse its payments first")}
    end
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
      <div :if={@notice} id={"notice-#{elem(@notice, 0)}"} class="notice" role="status">{elem(@notice, 1)}</div>
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

      <section class="card debts" id="debts">
        <div class="section-head">
          <h2>Debts</h2>
          <p class="muted"><strong>{ksh(@owed)}</strong> owed{if @unpaid_debts != [], do: " · #{length(@unpaid_debts)} to pay"}</p>
        </div>
        <ul :if={@unpaid_debts != []} class="debt-list">
          <.debt_row :for={d <- @unpaid_debts} d={d} paying={@paying} pools={@pools} />
        </ul>
        <p :if={@unpaid_debts == [] and @paid_debts == []} class="muted">Nobody to pay. Add what you owe below.</p>
        <p :if={@unpaid_debts == [] and @paid_debts != []} class="ok-line">All cleared 🎉</p>
        <h3 :if={@paid_debts != []} class="cat-title">Paid</h3>
        <ul :if={@paid_debts != []} class="debt-list">
          <.debt_row :for={d <- @paid_debts} d={d} paying={@paying} pools={@pools} />
        </ul>
        <form phx-submit="add_debt" id="add-debt-form" class="form">
          <div class="field-row">
            <label class="field"><span>Who</span><input type="text" name="debt[name]" maxlength="60" placeholder="e.g. John" required /></label>
            <label class="field"><span>Amount owed (KSh)</span><input type="number" inputmode="numeric" min="1" step="1" name="debt[amount]" placeholder="e.g. 12000" required /></label>
          </div>
          <button class="btn btn-primary" type="submit" phx-disable-with="Adding…">Add debt</button>
        </form>
      </section>

      <div :if={@active != []} class="section-title"><h2>Your goals</h2></div>

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
    assigns = assign(assigns, paid?: Debt.paid?(assigns.d), left: Debt.remaining(assigns.d))

    ~H"""
    <li class={["debt", @paid? && "paid"]}>
      <div class="debt-line">
        <span class={["check", @paid? && "on"]} aria-hidden="true">{if @paid?, do: "✓"}</span>
        <div class="debt-main">
          <strong>{@d.name}</strong>
          <span class="muted">
            <%= cond do %>
              <% @paid? -> %>Paid {Calendar.strftime(@d.paid_on, "%d %b %Y")}
              <% @d.paid_amount > 0 -> %>{ksh(@left)} left of {ksh(@d.amount)}
              <% true -> %>Not paid yet
            <% end %>
          </span>
        </div>
        <strong class="debt-amt">{ksh(if @paid?, do: @d.amount, else: @left)}</strong>
      </div>
      <div class="debt-actions">
        <button :if={!@paid? and @paying != @d.id} class="btn btn-primary btn-sm" phx-click="ask_pay" phx-value-id={@d.id}>Pay</button>
        <button :if={@paid? or @d.paid_amount > 0} class="btn btn-ghost btn-sm" phx-click="undo_debt" phx-value-id={@d.id}>Undo</button>
        <button :if={@d.paid_amount == 0} class="btn btn-ghost btn-sm" phx-click="remove_debt" phx-value-id={@d.id}>Remove</button>
      </div>
      <form :if={@paying == @d.id} phx-submit="pay_debt" class="pay-form">
        <input type="hidden" name="debt_id" value={@d.id} />
        <label class="field">
          <span>Pay (KSh)</span>
          <input type="number" inputmode="numeric" min="1" max={@left} step="1" name="amount" value={@left} required />
        </label>
        <label class="field">
          <span>Take it from</span>
          <select name="pool">
            <option :for={p <- @pools} value={p.id}>{p.name} · {ksh(p.balance)} saved</option>
            <option value="">Money kept elsewhere</option>
          </select>
        </label>
        <div class="form-actions">
          <button type="submit" class="btn btn-primary" phx-disable-with="Paying…">Pay and tick off</button>
          <button type="button" class="btn btn-ghost" phx-click="cancel_pay">Cancel</button>
        </div>
      </form>
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
