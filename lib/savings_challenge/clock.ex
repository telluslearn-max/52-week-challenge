defmodule SavingsChallenge.Clock do
  @moduledoc "Today's date in the user's timezone (fixed UTC offset, Kenya = +3)."

  @doc "Current local hour (0-23)."
  def hour, do: local_now().hour

  def local_now do
    offset = Application.get_env(:savings_challenge, :utc_offset_hours, 3)
    DateTime.utc_now() |> DateTime.add(offset * 3600, :second)
  end

  def today do
    offset = Application.get_env(:savings_challenge, :utc_offset_hours, 3)
    DateTime.utc_now() |> DateTime.add(offset * 3600, :second) |> DateTime.to_date()
  end
end
