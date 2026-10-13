defmodule SavingsChallenge.Repo.Migrations.AddCategoryToChallenges do
  use Ecto.Migration

  def change do
    alter table(:challenges) do
      add :category, :string, null: false, default: "general"
    end
  end
end
