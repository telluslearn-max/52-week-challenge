defmodule SavingsChallenge.Push do
  @moduledoc """
  Push subscriptions (one per device that turned notifications on) and sending.

  VAPID keys come from `config :savings_challenge, :vapid` (see runtime.exs).
  Delivery goes through `:push_sender` so tests can capture messages.
  """
  import Ecto.Query

  alias SavingsChallenge.{PushSubscription, Repo, WebPush}

  def config, do: Application.get_env(:savings_challenge, :vapid)
  def enabled?, do: not is_nil(config())
  def public_key, do: config() && config().public

  def count, do: Repo.aggregate(PushSubscription, :count)
  def list, do: Repo.all(from s in PushSubscription, order_by: [asc: s.id])
  def subscribed?(endpoint), do: is_binary(endpoint) and Repo.exists?(from s in PushSubscription, where: s.endpoint == ^endpoint)

  @doc "Saves (or refreshes) a device subscription."
  def subscribe(attrs) do
    changeset = PushSubscription.changeset(%PushSubscription{}, attrs)

    Repo.insert(changeset,
      on_conflict: {:replace, [:p256dh, :auth, :user_agent, :updated_at]},
      conflict_target: :endpoint
    )
  end

  def unsubscribe(endpoint) when is_binary(endpoint) do
    Repo.delete_all(from s in PushSubscription, where: s.endpoint == ^endpoint)
    :ok
  end

  @doc """
  Sends `message` (a map with :title, :body, :url) to every device. Expired
  subscriptions are removed. Returns `%{sent: n, removed: n, failed: n}`.
  """
  def broadcast(message) do
    payload = Jason.encode!(message)

    list()
    |> Task.async_stream(fn sub -> {sub, sender().(sub, payload, config())} end, timeout: 20_000, on_timeout: :kill_task)
    |> Enum.reduce(%{sent: 0, removed: 0, failed: 0}, fn
      {:ok, {_sub, :ok}}, acc ->
        %{acc | sent: acc.sent + 1}

      {:ok, {sub, :gone}}, acc ->
        Repo.delete(sub)
        %{acc | removed: acc.removed + 1}

      _other, acc ->
        %{acc | failed: acc.failed + 1}
    end)
  end

  defp sender, do: Application.get_env(:savings_challenge, :push_sender, &WebPush.deliver/3)
end
