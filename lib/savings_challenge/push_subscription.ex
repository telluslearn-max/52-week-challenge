defmodule SavingsChallenge.PushSubscription do
  use Ecto.Schema
  import Ecto.Changeset

  schema "push_subscriptions" do
    field :endpoint, :string
    field :p256dh, :string
    field :auth, :string
    field :user_agent, :string

    timestamps(type: :utc_datetime)
  end

  def changeset(sub, attrs) do
    sub
    |> cast(attrs, [:endpoint, :p256dh, :auth, :user_agent])
    |> validate_required([:endpoint, :p256dh, :auth])
    |> validate_length(:endpoint, max: 2000)
    |> validate_length(:user_agent, max: 255)
    |> validate_change(:endpoint, &check_endpoint/2)
    |> validate_change(:p256dh, &check_key(&1, &2, 65))
    |> validate_change(:auth, &check_key(&1, &2, 16))
    |> unique_constraint(:endpoint)
  end

  # We POST to this URL from the server, so only accept public https hosts
  # (browser push services), never localhost or raw IP addresses.
  defp check_endpoint(:endpoint, endpoint) do
    case URI.parse(endpoint) do
      %URI{scheme: "https", host: host} when is_binary(host) ->
        if host == "localhost" or match?({:ok, _}, :inet.parse_address(String.to_charlist(host))),
          do: [endpoint: "is not a valid push service address"],
          else: []

      _ ->
        [endpoint: "must be an https address"]
    end
  end

  defp check_key(field, value, size) do
    case Base.url_decode64(value, padding: false) do
      {:ok, bin} when byte_size(bin) == size -> []
      _ -> [{field, "is not a valid key"}]
    end
  end
end
