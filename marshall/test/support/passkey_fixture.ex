defmodule Marshall.PasskeyFixture do
  @moduledoc "Synthetic P-256 WebAuthn authenticator for real registration and assertion verification."
  alias Marshall.Accounts.{Security, User}

  def user(admin \\ false),
    do:
      Ash.Seed.seed!(User, %{
        email: "u-#{binary_part(Ash.UUID.generate(), 0, 16)}@example.test",
        administrator: admin
      })

  def login(user) do
    {:ok, token, %{"jti" => jti}} = AshAuthentication.Jwt.token_for_user(user)
    {:ok, _} = Security.primary(user, jti)
    {Security.bind(user, jti), token}
  end

  def action(actor, operation, payload \\ %{}) do
    User
    |> Ash.ActionInput.for_action(:security, %{operation: operation, payload: payload},
      actor: actor
    )
    |> Ash.run_action()
  end

  def authenticator do
    {<<4, x::binary-size(32), y::binary-size(32)>>, private} =
      :crypto.generate_key(:ecdh, :secp256r1)

    %{
      id: :crypto.strong_rand_bytes(32),
      private: private,
      cose: %{1 => 2, 3 => -7, -1 => 1, -2 => bytes(x), -3 => bytes(y)}
    }
  end

  def register(actor, authenticator \\ authenticator()) do
    {:ok, challenge} = action(actor, :begin_register)
    payload = registration(challenge, authenticator)
    {:ok, %{registered: true}} = action(actor, :finish_register, payload)
    authenticator
  end

  def registration(challenge, authenticator, opts \\ []) do
    client = client_data(challenge, "webauthn.create", opts)
    flags = Keyword.get(opts, :flags, 0x45)

    auth_data =
      :crypto.hash(:sha256, challenge.publicKey.rp.id) <>
        <<flags, 0::32, 0::128, byte_size(authenticator.id)::16>> <>
        authenticator.id <> CBOR.encode(authenticator.cose)

    attestation =
      CBOR.encode(%{"fmt" => "none", "attStmt" => %{}, "authData" => bytes(auth_data)})

    %{
      "id" => challenge.id,
      "client_data_json" => encode(client),
      "attestation_object" => encode(attestation),
      "label" => "Test passkey"
    }
  end

  def assertion(challenge, authenticator, opts \\ []) do
    client = client_data(challenge, "webauthn.get", opts)
    flags = Keyword.get(opts, :flags, 5)

    auth_data =
      :crypto.hash(:sha256, challenge.publicKey.rpId) <>
        <<flags, Keyword.get(opts, :counter, 0)::32>>

    signature =
      :crypto.sign(:ecdsa, :sha256, auth_data <> :crypto.hash(:sha256, client), [
        authenticator.private,
        :secp256r1
      ])

    %{
      "id" => challenge.id,
      "raw_id" => encode(authenticator.id),
      "client_data_json" => encode(client),
      "authenticator_data" => encode(auth_data),
      "signature" => encode(signature)
    }
  end

  def verify(actor, authenticator) do
    {:ok, challenge} = action(actor, :begin_verify)
    action(actor, :finish_verify, assertion(challenge, authenticator))
  end

  def elevate(user) do
    {actor, token} = login(user)
    key = register(actor)
    {:ok, %{verified: true}} = verify(actor, key)

    actor
    |> Ash.Resource.put_metadata(:token, token)
    |> Ash.Resource.put_metadata(:test_authenticator, key)
  end

  @doc "Seed completed authority for unrelated admin tests; ceremony tests use real signatures above."
  def verified_session(user) do
    alias Marshall.Accounts.{Passkey, Verification}
    alias Marshall.Compute.Ledger
    {actor, token} = login(user)
    user = Ledger.update!(user, :security_state, %{mfa_enabled: true})

    key =
      Ash.Seed.seed!(Passkey, %{
        user_id: user.id,
        credential_id: :crypto.strong_rand_bytes(32),
        public_key: %{1 => 2},
        label: "Fixture"
      })

    [proof] = Ledger.read!(Verification, id: Security.jti(actor))
    now = Ledger.now()

    Ledger.update!(proof, :verify, %{
      verified_at: now,
      elevated_until: DateTime.add(now, 900),
      credential_id: key.id
    })

    user |> Security.bind(Security.jti(actor)) |> Ash.Resource.put_metadata(:token, token)
  end

  def cleanup(user) do
    id = Ecto.UUID.dump!(user.id)

    for table <- ["account_passkey_challenges", "account_verifications", "account_passkeys"] do
      Ecto.Adapters.SQL.query!(Marshall.Repo, "DELETE FROM " <> table <> " WHERE user_id=$1", [id])
    end

    Ecto.Adapters.SQL.query!(Marshall.Repo, "DELETE FROM tokens WHERE subject=$1", [
      "user?id=" <> user.id
    ])
  end

  defp client_data(challenge, type, opts),
    do:
      Jason.encode!(%{
        type: type,
        challenge: Keyword.get(opts, :challenge, challenge.publicKey.challenge),
        origin: Keyword.get(opts, :origin, MarshallWeb.Endpoint.url()),
        crossOrigin: false
      })

  defp bytes(value), do: %CBOR.Tag{tag: :bytes, value: value}
  defp encode(value), do: Base.url_encode64(value, padding: false)
end
