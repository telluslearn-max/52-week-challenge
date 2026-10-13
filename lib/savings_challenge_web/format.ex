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
end
