defmodule SavingsChallenge.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      SavingsChallenge.Repo,
      {Phoenix.PubSub, name: SavingsChallenge.PubSub},
      SavingsChallengeWeb.Endpoint
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: SavingsChallenge.Supervisor)
  end

  @impl true
  def config_change(changed, _new, removed) do
    SavingsChallengeWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
