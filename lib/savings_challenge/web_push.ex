defmodule SavingsChallenge.WebPush do
  @moduledoc """
  Web Push without third-party libraries:

    * RFC 8291 message encryption (`aes128gcm`, single record)
    * RFC 8292 VAPID authentication (ES256 JWT)
    * delivery over HTTPS

  `encrypt/4` is deterministic when given `:as_private` and `:salt`, which is how
  it is checked against the RFC 8291 appendix A test vector.
  """

  @record_size 4096
  # Push services cap the request body at 4096 bytes: 86 bytes of header
  # (salt 16 + record size 4 + key length 1 + key 65) and 17 of padding/tag.
  @max_payload 4096 - 86 - 17

  ## Encoding helpers

  def b64d(string), do: Base.url_decode64!(string, padding: false)
  def b64e(binary), do: Base.url_encode64(binary, padding: false)

  ## RFC 8291

  @doc """
  Encrypts `payload` for a subscription's `p256dh` public key and `auth` secret
  (both base64url). Returns the request body.
  """
  def encrypt(payload, p256dh, auth, opts \\ []) when is_binary(payload) do
    if byte_size(payload) > @max_payload, do: raise(ArgumentError, "payload too large for one record")

    ua_public = b64d(p256dh)
    auth_secret = b64d(auth)

    {as_public, as_private} =
      case opts[:as_private] do
        nil -> :crypto.generate_key(:ecdh, :secp256r1)
        priv -> :crypto.generate_key(:ecdh, :secp256r1, priv)
      end

    salt = opts[:salt] || :crypto.strong_rand_bytes(16)

    shared = :crypto.compute_key(:ecdh, ua_public, as_private, :secp256r1)
    prk_key = hkdf_extract(auth_secret, shared)
    ikm = hkdf_expand(prk_key, "WebPush: info" <> <<0>> <> ua_public <> as_public, 32)

    prk = hkdf_extract(salt, ikm)
    cek = hkdf_expand(prk, "Content-Encoding: aes128gcm" <> <<0>>, 16)
    nonce = hkdf_expand(prk, "Content-Encoding: nonce" <> <<0>>, 12)

    # 0x02 marks the last (and only) record.
    {ciphertext, tag} = :crypto.crypto_one_time_aead(:aes_128_gcm, cek, nonce, payload <> <<2>>, <<>>, 16, true)

    salt <> <<@record_size::32>> <> <<byte_size(as_public)::8>> <> as_public <> ciphertext <> tag
  end

  defp hkdf_extract(salt, ikm), do: :crypto.mac(:hmac, :sha256, salt, ikm)
  defp hkdf_expand(prk, info, length), do: :crypto.mac(:hmac, :sha256, prk, info <> <<1>>) |> binary_part(0, length)

  ## RFC 8292 (VAPID)

  @doc "The `Authorization` header value for pushing to `endpoint`."
  def vapid_authorization(endpoint, %{public: public, private: private, subject: subject}, now \\ System.system_time(:second)) do
    uri = URI.parse(endpoint)
    audience = "#{uri.scheme}://#{uri.host}" <> if(uri.port in [nil, 443], do: "", else: ":#{uri.port}")

    header = b64e(~s({"typ":"JWT","alg":"ES256"}))
    claims = b64e(Jason.encode!(%{aud: audience, exp: now + 12 * 3600, sub: subject}))
    signing_input = header <> "." <> claims

    signature =
      :ecdsa
      |> :crypto.sign(:sha256, signing_input, [b64d(private), :secp256r1])
      |> der_to_raw()

    "vapid t=#{signing_input}.#{b64e(signature)}, k=#{public}"
  end

  @doc "JWT signatures are raw `r || s` (64 bytes), not DER."
  def der_to_raw(der) do
    {:"ECDSA-Sig-Value", r, s} = :public_key.der_decode(:"ECDSA-Sig-Value", der)
    pad(:binary.encode_unsigned(r)) <> pad(:binary.encode_unsigned(s))
  end

  def raw_to_der(<<r::binary-size(32), s::binary-size(32)>>) do
    :public_key.der_encode(:"ECDSA-Sig-Value", {:"ECDSA-Sig-Value", :binary.decode_unsigned(r), :binary.decode_unsigned(s)})
  end

  defp pad(bin) when byte_size(bin) < 32, do: :binary.copy(<<0>>, 32 - byte_size(bin)) <> bin
  defp pad(bin), do: bin

  @doc "Generates a VAPID key pair as base64url strings."
  def generate_vapid_keys do
    {public, private} = :crypto.generate_key(:ecdh, :secp256r1)
    %{public: b64e(public), private: b64e(private)}
  end

  ## Delivery

  @doc """
  Encrypts and POSTs `payload` to a subscription (`%{endpoint, p256dh, auth}`).
  Returns `:ok`, `:gone` (subscription expired: delete it) or `{:error, reason}`.
  """
  def deliver(subscription, payload, vapid) do
    body = encrypt(payload, subscription.p256dh, subscription.auth)

    headers = [
      {~c"authorization", String.to_charlist(vapid_authorization(subscription.endpoint, vapid))},
      {~c"content-encoding", ~c"aes128gcm"},
      {~c"ttl", ~c"86400"},
      {~c"urgency", ~c"normal"}
    ]

    ssl = [
      verify: :verify_peer,
      cacerts: :public_key.cacerts_get(),
      customize_hostname_check: [match_fun: :public_key.pkix_verify_hostname_match_fun(:https)]
    ]

    request = {String.to_charlist(subscription.endpoint), headers, ~c"application/octet-stream", body}

    case :httpc.request(:post, request, [ssl: ssl, timeout: 15_000], []) do
      {:ok, {{_, status, _}, _, _}} when status in 200..299 -> :ok
      {:ok, {{_, status, _}, _, _}} when status in [404, 410] -> :gone
      {:ok, {{_, status, _}, _, _}} -> {:error, {:http, status}}
      {:error, reason} -> {:error, reason}
    end
  end
end
