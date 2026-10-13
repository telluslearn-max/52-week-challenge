defmodule SavingsChallenge.PushStub do
  @moduledoc "Stands in for the push services in tests: records messages, can simulate expiry/failure."
  use Agent

  def start_link(_opts), do: Agent.start_link(fn -> [] end, name: __MODULE__)
  def all, do: Agent.get(__MODULE__, &Enum.reverse/1)
  def clear, do: Agent.update(__MODULE__, fn _ -> [] end)

  def deliver(sub, payload, _vapid) do
    cond do
      String.contains?(sub.endpoint, "gone") -> :gone
      String.contains?(sub.endpoint, "broken") -> {:error, {:http, 500}}
      true ->
        Agent.update(__MODULE__, &[%{endpoint: sub.endpoint, message: Jason.decode!(payload)} | &1])
        :ok
    end
  end
end
