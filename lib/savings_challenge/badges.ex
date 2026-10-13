defmodule SavingsChallenge.Badges do
  @moduledoc "Badges are derived from a plan snapshot; nothing about them is stored."

  @doc "Every badge with `earned?`, in display order."
  def all(snap) do
    [
      {"first", "First deposit", "🌱", "Record your first deposit", snap.saved > 0},
      {"q25", "25% there", "🥉", "Reach 25% of your goal", snap.percent >= 25},
      {"q50", "Halfway", "🥈", "Reach 50% of your goal", snap.percent >= 50},
      {"q75", "75% there", "🥇", "Reach 75% of your goal", snap.percent >= 75},
      {"streak3", "3 in a row", "🔥", "Hit your target 3 times in a row", snap.best_streak >= 3},
      {"streak7", "7 in a row", "⚡", "Hit your target 7 times in a row", snap.best_streak >= 7},
      {"ahead", "Ahead of plan", "⏩", "Save more than the plan asks so far", snap.saved > 0 and snap.saved > snap.planned_to_date},
      {"done", "Goal reached", "🏆", "Reach your goal", snap.goal_reached?}
    ]
    |> Enum.map(fn {key, label, icon, hint, earned?} -> %{key: key, label: label, icon: icon, hint: hint, earned?: earned?} end)
  end
end
