defmodule Susan.Fixtures do
  @moduledoc "Deterministic configuration, push keys and signed pokes for tests."

  alias Susan.{Config, Keyring, PushKey}

  @apns_topic "dev.overalls.mila"
  @deployment "control.example.test"

  @spec deployment() :: String.t()
  def deployment, do: @deployment

  @spec keyring(pos_integer()) :: Keyring.t()
  def keyring(active \\ 1) do
    keys = Map.new(1..2, fn id -> {id, :crypto.hash(:sha256, "susan-test-key-#{id}")} end)
    %Keyring{active: active, keys: keys}
  end

  @spec config(keyword()) :: Config.t()
  def config(overrides \\ []) do
    ec = :public_key.generate_key({:namedCurve, :secp256r1})
    rsa = :persistent_term.get({__MODULE__, :rsa}, nil) || generate_rsa()

    struct!(
      Config,
      Keyword.merge(
        [
          bind: {127, 0, 0, 1},
          port: 4100,
          trusted_proxies: [{127, 0, 0, 1}],
          apns_topics: [@apns_topic],
          fcm_app_ids: [@apns_topic],
          apns: %{key: ec, key_id: "ABCDEFGHIJ", team_id: "TEAM123456"},
          fcm: %{
            project_id: "overalls-test",
            client_email: "relay@overalls-test.iam.example",
            private_key: rsa
          },
          keyring: keyring(),
          repo: [],
          limits: Susan.RateLimiter.defaults()
        ],
        overrides
      )
    )
  end

  defp generate_rsa do
    key = :public_key.generate_key({:rsa, 2048, 65_537})
    :persistent_term.put({__MODULE__, :rsa}, key)
    key
  end

  @spec apns_token() :: String.t()
  def apns_token, do: :crypto.strong_rand_bytes(32) |> Base.encode16(case: :lower)

  @spec fcm_token() :: String.t()
  def fcm_token, do: "fcm:" <> Base.url_encode64(:crypto.strong_rand_bytes(90), padding: false)

  @spec push_key(Config.t(), keyword()) :: {String.t(), PushKey.t()}
  def push_key(config, options \\ []) do
    provider = Keyword.get(options, :provider, :apns)

    fields = %{
      provider: provider,
      environment: Keyword.get(options, :environment, :production),
      app_id: @apns_topic,
      deployment: Keyword.get(options, :deployment, @deployment),
      token:
        Keyword.get_lazy(options, :token, fn ->
          if provider == :apns, do: apns_token(), else: fcm_token()
        end),
      issued_at: Keyword.get(options, :issued_at, System.os_time(:second))
    }

    {:ok, encoded, key} = PushKey.seal(Keyword.get(options, :keyring, config.keyring), fields)
    {encoded, key}
  end

  @spec install() :: {binary(), binary()}
  def install, do: :crypto.generate_key(:eddsa, :ed25519)

  @doc "The opaque 22-character collapse id Marshall would send for a collapse group label."
  @spec collapse_id(String.t()) :: String.t()
  def collapse_id(label),
    do: :crypto.hash(:sha256, label) |> Base.url_encode64(padding: false) |> binary_part(0, 22)

  @doc """
  Builds a signed poke input for `Susan.Poke.handle/2`. `:collapse_id` names a
  collapse group label; the body carries its opaque id. The signature covers
  `OverallsProtocol.SusanPoke.signed_message/1` of `:signed_body` (default: the body).
  """
  @spec poke(String.t(), {binary(), binary()}, keyword()) :: Susan.Poke.input()
  def poke(push_key, {public, private}, options \\ []) do
    now = Keyword.get(options, :now, System.os_time(:second))

    body =
      %{
        "push_key" => push_key,
        "deployment" => Keyword.get(options, :deployment, @deployment),
        "ciphertext" =>
          Keyword.get(
            options,
            :ciphertext,
            Base.url_encode64(:crypto.strong_rand_bytes(140), padding: false)
          ),
        "kind" => "needs_input",
        "collapse_id" => collapse_id(Keyword.get(options, :collapse_id, "thread-1")),
        "delivery_id" => Keyword.get_lazy(options, :delivery_id, &PushKey.uuid/0),
        "nonce" =>
          Base.url_encode64(
            Keyword.get_lazy(options, :nonce, fn -> :crypto.strong_rand_bytes(16) end),
            padding: false
          ),
        "issued_at" => Keyword.get(options, :issued_at, now)
      }
      |> Map.merge(Keyword.get(options, :extra, %{}))
      |> JSON.encode!()

    signature =
      :crypto.sign(
        :eddsa,
        :none,
        OverallsProtocol.SusanPoke.signed_message(Keyword.get(options, :signed_body, body)),
        [private, :ed25519]
      )

    %{
      body: body,
      install_key: Base.url_encode64(public, padding: false),
      signature: Base.url_encode64(signature, padding: false),
      source: Keyword.get_lazy(options, :source, fn -> :crypto.strong_rand_bytes(32) end),
      now: now
    }
  end
end
