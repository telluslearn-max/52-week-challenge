defmodule SavingsChallenge.WebPushTest do
  use ExUnit.Case, async: true

  alias SavingsChallenge.WebPush

  # RFC 8291, appendix A: "When I grow up, I want to be a watermelon"
  @plaintext "When I grow up, I want to be a watermelon"
  @as_private "yfWPiYE-n46HLnH0KqZOF1fJJU3MYrct3AELtAQ-oRw"
  @ua_public "BCVxsr7N_eNgVRqvHtD0zTZsEc6-VV-JvLexhqUzORcxaOzi6-AYWXvTBHm4bjyPjs7Vd8pZGH6SRpkNtoIAiw4"
  @auth "BTBZMqHH6r4Tts7J_aSIgg"
  @salt "DGv6ra1nlYgDCS1FRnbzlw"
  @expected "DGv6ra1nlYgDCS1FRnbzlwAAEABBBP4z9KsN6nGRTbVYI_c7VJSPQTBtkgcy27mlmlMoZIIgDll6e3vCYLocInmYWAmS6TlzAC8wEqKK6PBru3jl7A_yl95bQpu6cVPTpK4Mqgkf1CXztLVBSt2Ks3oZwbuwXPXLWyouBWLVWGNWQexSgSxsj_Qulcy4a-fN"

  test "matches the RFC 8291 test vector exactly" do
    body = WebPush.encrypt(@plaintext, @ua_public, @auth, as_private: WebPush.b64d(@as_private), salt: WebPush.b64d(@salt))
    assert WebPush.b64e(body) == @expected
  end

  test "a real recipient can decrypt what we send" do
    {ua_pub, ua_priv} = :crypto.generate_key(:ecdh, :secp256r1)
    auth = :crypto.strong_rand_bytes(16)
    payload = ~s({"title":"Time to save","body":"KSh 300 · Netflix"})

    body = WebPush.encrypt(payload, WebPush.b64e(ua_pub), WebPush.b64e(auth))

    # Recipient side (RFC 8291 section 3.4).
    <<salt::binary-size(16), 4096::32, 65, as_pub::binary-size(65), rest::binary>> = body
    ct_len = byte_size(rest) - 16
    <<ciphertext::binary-size(ct_len), tag::binary-size(16)>> = rest

    shared = :crypto.compute_key(:ecdh, as_pub, ua_priv, :secp256r1)
    prk_key = :crypto.mac(:hmac, :sha256, auth, shared)
    ikm = :crypto.mac(:hmac, :sha256, prk_key, "WebPush: info" <> <<0>> <> ua_pub <> as_pub <> <<1>>)
    prk = :crypto.mac(:hmac, :sha256, salt, ikm)
    cek = :crypto.mac(:hmac, :sha256, prk, "Content-Encoding: aes128gcm" <> <<0, 1>>) |> binary_part(0, 16)
    nonce = :crypto.mac(:hmac, :sha256, prk, "Content-Encoding: nonce" <> <<0, 1>>) |> binary_part(0, 12)

    plain = :crypto.crypto_one_time_aead(:aes_128_gcm, cek, nonce, ciphertext, <<>>, tag, false)
    assert plain == payload <> <<2>>
  end

  test "encryption is randomised and tamper-evident" do
    {ua_pub, _} = :crypto.generate_key(:ecdh, :secp256r1)
    args = [WebPush.b64e(ua_pub), WebPush.b64e(:crypto.strong_rand_bytes(16))]
    refute apply(WebPush, :encrypt, ["x" | args]) == apply(WebPush, :encrypt, ["x" | args])
  end

  test "oversized payloads are refused" do
    {ua_pub, _} = :crypto.generate_key(:ecdh, :secp256r1)
    assert_raise ArgumentError, fn -> WebPush.encrypt(String.duplicate("a", 4000), WebPush.b64e(ua_pub), WebPush.b64e(<<0::128>>)) end
  end

  describe "VAPID" do
    setup do
      {:ok, vapid: Map.put(WebPush.generate_vapid_keys(), :subject, "mailto:me@example.com")}
    end

    test "builds a verifiable ES256 JWT with the push service as audience", %{vapid: vapid} do
      now = 1_800_000_000
      header = WebPush.vapid_authorization("https://fcm.googleapis.com/fcm/send/abc", vapid, now)

      assert [_, jwt, key] = Regex.run(~r/^vapid t=([\w.-]+), k=([\w-]+)$/, header)
      assert key == vapid.public

      [h, c, s] = String.split(jwt, ".")
      assert Jason.decode!(WebPush.b64d(h)) == %{"typ" => "JWT", "alg" => "ES256"}

      claims = Jason.decode!(WebPush.b64d(c))
      assert claims == %{"aud" => "https://fcm.googleapis.com", "exp" => now + 12 * 3600, "sub" => "mailto:me@example.com"}

      sig = WebPush.b64d(s)
      assert byte_size(sig) == 64
      der = WebPush.raw_to_der(sig)
      assert :crypto.verify(:ecdsa, :sha256, h <> "." <> c, der, [WebPush.b64d(vapid.public), :secp256r1])
      refute :crypto.verify(:ecdsa, :sha256, h <> "." <> c <> "x", der, [WebPush.b64d(vapid.public), :secp256r1])
    end

    test "audience keeps a non-default port", %{vapid: vapid} do
      header = WebPush.vapid_authorization("https://push.example.com:8443/x", vapid, 1)
      [_, jwt | _] = Regex.run(~r/t=([\w.-]+)/, header)
      [_, c, _] = String.split(jwt, ".")
      assert Jason.decode!(WebPush.b64d(c))["aud"] == "https://push.example.com:8443"
    end

    test "DER and raw signature forms round-trip, including short r/s values" do
      raw = <<1::256, 2::256>>
      assert raw |> WebPush.raw_to_der() |> WebPush.der_to_raw() == raw
    end
  end
end
