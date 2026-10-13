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
end
