defmodule SavingsChallenge.Clock do
  @moduledoc "Today's date in the user's timezone (fixed UTC offset, Kenya = +3)."

  def today do
    offset = Application.get_env(:savings_challenge, :utc_offset_hours, 3)
    DateTime.utc_now() |> DateTime.add(offset * 3600, :second) |> DateTime.to_date()
  end
end
