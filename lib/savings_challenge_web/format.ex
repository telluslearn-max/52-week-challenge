defmodule SavingsChallengeWeb.Format do
  @moduledoc "Number formatting helpers shared by the LiveViews."

  def ksh(n) when is_integer(n), do: (if n < 0, do: "-KSh ", else: "KSh ") <> num(abs(n))

  def num(n) when is_integer(n) do
    n
    |> Integer.to_string()
    |> String.reverse()
    |> String.replace(~r/(\d{3})(?=\d)/, "\\1,")
    |> String.reverse()
  end

  def unit_label("day"), do: "Day"
  def unit_label("month"), do: "Month"
  def unit_label(_), do: "Week"

  def unit_word(unit), do: unit |> unit_label() |> String.downcase()
  def unit_plural(unit), do: unit_word(unit) <> "s"

  def every("day"), do: "daily"
  def every("month"), do: "monthly"
  def every(_), do: "weekly"

  @doc "Human wording for a due date relative to today."
  def due_text(due, today) do
    case Date.diff(due, today) do
      0 -> "Due today"
      1 -> "Due tomorrow"
      n when n > 1 -> "Due in #{n} days"
      -1 -> "Overdue by 1 day"
      n -> "Overdue by #{abs(n)} days"
    end
  end

  def recurrence_label("weekly"), do: "repeats every week"
  def recurrence_label("monthly"), do: "repeats every month"
  def recurrence_label("quarterly"), do: "repeats every 3 months"
  def recurrence_label("yearly"), do: "repeats every year"
  def recurrence_label(_), do: "one-off"
end
