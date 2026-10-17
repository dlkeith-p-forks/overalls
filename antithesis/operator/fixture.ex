defmodule OverallsAntithesis.Fixture do
  @moduledoc """
  Closed synthetic identity and repository bootstrap for the isolated harness.

  This file is loaded only by the enrollment operator's fixed release invocation.
  All mutations use the same Ash actions as an authenticated browser actor.
  """

  alias Marshall.Accounts.{Security, User}
  alias Marshall.Enrico.Catalog

  @bootstrap_stage "/run/overalls-control-secrets/bootstrap-stage"

  @type authenticator :: %{id: binary(), private: binary(), cose: map()}
  @type account :: %{id: String.t(), email: String.t(), key: authenticator()}
  @type manifest :: %{
          String.t() => String.t() | integer() | map()
        }

  # @cc [owner:ghuntley,label:security;verification] fixture-closed-runtime
  # Only the isolated enrollment operator may invoke these fixed operations.
  # Request data MUST NOT select an actor, email, source, code path, or command.
  @spec main([String.t()]) :: :ok | no_return()
  def main([operation, manifest_path, result_path])
      when operation in ["bootstrap", "refresh_repository", "demote_admin_b"] do
    if System.get_env("MARSHALL_INSTANCE_ID") != "enrollment-operator" or
         Application.get_env(:marshall, :operator_mode) != true or
         not File.regular?("/run/overalls-oracle/fixture.json") do
      System.halt(1)
    end

    case operation do
      "bootstrap" -> bootstrap(manifest_path)
      "refresh_repository" -> refresh_repository(manifest_path, result_path)
      "demote_admin_b" -> demote_admin_b(manifest_path, result_path)
    end
  rescue
    _ -> System.halt(1)
  catch
    _, _ -> System.halt(1)
  end

  def main(_), do: System.halt(1)

  # @cc [owner:ghuntley,label:security;verification] fixture-real-ash-authority
  # Bootstrap MUST establish each account through magic-link sign-in, register
  # and verify real WebAuthn credentials through User.security, and use the
  # elevated administrator actions for role grant and repository registration.
  # It MUST publish the manifest only after those actions commit successfully.
  @spec bootstrap(String.t()) :: :ok
  defp bootstrap(path) do
    if File.exists?(path), do: verify_existing!(path), else: create_fixture!(path)
  end

  @spec create_fixture!(String.t()) :: :ok
  defp create_fixture!(path) do
    stage!("fixture_id")
    fixture_id = fixture_id!()
    admin_a = create_account!("fixture-admin-a-#{fixture_id}@example.test", :admin_a)
    admin_b = create_account!("fixture-admin-b-#{fixture_id}@example.test", :admin_b)
    target = create_account!("fixture-target-#{fixture_id}@example.test", :target)

    stage!("admin_a.elevate")
    admin_actor = login!(admin_a.email)
    verify!(admin_actor, admin_a.key)

    stage!("admin_b.grant")

    {:ok, %{administrator: true}} =
      User
      |> Ash.ActionInput.for_action(
        :set_administrator,
        %{user_id: admin_b.id, administrator: true},
        actor: admin_actor
      )
      |> Ash.run_action()

    stage!("repository.register")
    {:ok, repository} = Catalog.register(admin_actor, "fixture", "demo")
    # Catalog.register commits the canonical lowercase GitHub source; the
    # manifest publishes that committed identity, which live SQL, the Enrico
    # refresh request and the origin fixture's served path all share.
    %Marshall.Enrico.Repository{namespace: "github", owner: "fixture", name: "demo"} = repository

    manifest = %{
      "schema_version" => 1,
      "fixture_id" => fixture_id,
      "namespace" => repository.namespace,
      "owner" => repository.owner,
      "name" => repository.name,
      "repository_id" => repository.id,
      "registered_by_id" => admin_a.id,
      "webauthn_origin" => MarshallWeb.Endpoint.url(),
      "webauthn_rp_id" => URI.parse(MarshallWeb.Endpoint.url()).host,
      "admin_a" => encode_account(admin_a),
      "admin_b" => encode_account(admin_b),
      "target" => encode_account(target)
    }

    stage!("manifest.publish")
    write_private!(path, manifest)
    stage!("complete")
  end

  @spec stage!(String.t()) :: :ok
  defp stage!(stage) do
    temporary = @bootstrap_stage <> ".new"
    :ok = File.write(temporary, stage <> "\n")
    :ok = File.chmod(temporary, 0o600)
    :ok = File.rename(temporary, @bootstrap_stage)
  end

  @spec fixture_id!() :: String.t()
  defp fixture_id! do
    %{"fixture_id" => id} =
      "/run/overalls-oracle/fixture.json" |> File.read!() |> JSON.decode!()

    if is_binary(id) and Regex.match?(~r/\A[0-9a-f]{32}\z/, id), do: id, else: raise("fixture")
  end

  @spec create_account!(String.t(), :admin_a | :admin_b | :target) :: account()
  defp create_account!(email, role) do
    stage!("#{role}.login")
    actor = login!(email)
    stage!("#{role}.authenticator")
    key = authenticator()
    stage!("#{role}.begin_register")
    {:ok, challenge} = security(actor, :begin_register)

    stage!("#{role}.finish_register")

    {:ok, %{registered: true}} =
      security(actor, :finish_register, registration(challenge, key))

    stage!("#{role}.verify")
    verify!(actor, key)
    %{id: actor.id, email: email, key: key}
  end

  @spec login!(String.t()) :: User.t()
  defp login!(email) do
    strategy = AshAuthentication.Info.strategy!(User, :magic_link)

    {:ok, magic_token} =
      AshAuthentication.Strategy.MagicLink.request_token_for_identity(strategy, email)

    {:ok, user} =
      User
      |> Ash.Changeset.new()
      |> Ash.Changeset.set_context(%{private: %{ash_authentication?: true}})
      |> Ash.Changeset.for_create(:sign_in_with_magic_link, %{
        token: magic_token,
        remember_me: true
      })
      |> Ash.create()

    token = Ash.Resource.get_metadata(user, :token)
    {:ok, %{"jti" => jti}, User} = AshAuthentication.Jwt.verify(token, User)
    {:ok, _} = Security.primary(user, jti)
    Security.bind(user, jti)
  end

  @spec security(User.t(), atom(), map()) :: {:ok, map()} | {:error, term()}
  defp security(actor, operation, payload \\ %{}) do
    User
    |> Ash.ActionInput.for_action(:security, %{operation: operation, payload: payload},
      actor: actor
    )
    |> Ash.run_action()
  end

  @spec authenticator() :: authenticator()
  defp authenticator do
    {<<4, x::binary-size(32), y::binary-size(32)>>, private} =
      :crypto.generate_key(:ecdh, :secp256r1)

    %{
      id: :crypto.strong_rand_bytes(32),
      private: private,
      cose: %{1 => 2, 3 => -7, -1 => 1, -2 => bytes(x), -3 => bytes(y)}
    }
  end

  @spec registration(map(), authenticator()) :: map()
  defp registration(challenge, key) do
    client = client_data(challenge.publicKey.challenge, "webauthn.create")

    auth_data =
      :crypto.hash(:sha256, challenge.publicKey.rp.id) <>
        <<0x45, 0::32, 0::128, byte_size(key.id)::16>> <>
        key.id <> CBOR.encode(key.cose)

    attestation =
      CBOR.encode(%{"fmt" => "none", "attStmt" => %{}, "authData" => bytes(auth_data)})

    %{
      "id" => challenge.id,
      "client_data_json" => encode(client),
      "attestation_object" => encode(attestation),
      "label" => "Antithesis fixture"
    }
  end

  @spec verify!(User.t(), authenticator()) :: :ok
  defp verify!(actor, key) do
    {:ok, challenge} = security(actor, :begin_verify)
    client = client_data(challenge.publicKey.challenge, "webauthn.get")
    auth_data = :crypto.hash(:sha256, challenge.publicKey.rpId) <> <<5, 0::32>>

    signature =
      :crypto.sign(:ecdsa, :sha256, auth_data <> :crypto.hash(:sha256, client), [
        key.private,
        :secp256r1
      ])

    {:ok, %{verified: true}} =
      security(actor, :finish_verify, %{
        "id" => challenge.id,
        "raw_id" => encode(key.id),
        "client_data_json" => encode(client),
        "authenticator_data" => encode(auth_data),
        "signature" => encode(signature)
      })

    :ok
  end

  @spec client_data(String.t(), String.t()) :: String.t()
  defp client_data(challenge, kind) do
    JSON.encode!(%{
      type: kind,
      challenge: challenge,
      origin: MarshallWeb.Endpoint.url(),
      crossOrigin: false
    })
  end

  @spec bytes(binary()) :: CBOR.Tag.t()
  defp bytes(value), do: %CBOR.Tag{tag: :bytes, value: value}

  @spec encode(binary()) :: String.t()
  defp encode(value), do: Base.url_encode64(value, padding: false)

  @spec encode_account(account()) :: map()
  defp encode_account(account) do
    %{
      "id" => account.id,
      "email" => account.email,
      "authenticator" => %{
        "id" => encode(account.key.id),
        "private_sec1_der" => encode(sec1_der(account.key.private))
      }
    }
  end

  @spec sec1_der(binary()) :: binary()
  defp sec1_der(<<private::binary-size(32)>>) do
    <<0x30, 0x31, 0x02, 0x01, 0x01, 0x04, 0x20>> <>
      private <> <<0xA0, 0x0A, 0x06, 0x08, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x03, 0x01, 0x07>>
  end

  @spec decode_account!(map()) :: account()
  defp decode_account!(%{"id" => id, "email" => email, "authenticator" => key}) do
    %{"id" => encoded_id, "private_sec1_der" => encoded_private} = key
    {:ok, credential_id} = Base.url_decode64(encoded_id, padding: false)

    {:ok,
     <<0x30, 0x31, 0x02, 0x01, 0x01, 0x04, 0x20, private::binary-size(32), 0xA0, 0x0A, 0x06, 0x08,
       0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x03, 0x01, 0x07>>} =
      Base.url_decode64(encoded_private, padding: false)

    true = byte_size(credential_id) == 32 and byte_size(private) == 32
    %{id: id, email: email, key: %{id: credential_id, private: private, cose: %{}}}
  end

  @spec read_manifest!(String.t()) :: manifest()
  def read_manifest!(path) do
    manifest = path |> File.read!() |> JSON.decode!()
    true = manifest["schema_version"] == 1 and manifest["fixture_id"] == fixture_id!()
    true = manifest["namespace"] == "github" and manifest["owner"] == "fixture"
    true = manifest["name"] == "demo"
    manifest
  end

  @spec verify_existing!(String.t()) :: :ok
  defp verify_existing!(path) do
    manifest = read_manifest!(path)
    admin_a = decode_account!(manifest["admin_a"])
    admin_b = decode_account!(manifest["admin_b"])
    target = decode_account!(manifest["target"])

    for account <- [admin_a, admin_b, target] do
      %User{id: id, email: email, mfa_enabled: true, deleted_at: nil} =
        Security.current(account.id)

      true = id == account.id
      true = to_string(email) == account.email
    end

    %User{administrator: true} = Security.current(admin_a.id)

    [
      %Marshall.Enrico.Repository{
        id: id,
        namespace: "github",
        owner: "fixture",
        name: "demo",
        registered_by_id: registered_by_id
      }
    ] =
      Marshall.Compute.Ledger.read!(Marshall.Enrico.Repository, id: manifest["repository_id"])

    true = id == manifest["repository_id"]
    true = registered_by_id == admin_a.id
    :ok
  end

  # @cc [owner:ghuntley,label:security] fixture-replay-current-authority
  # Later fixture mutations MUST obtain a fresh stored login and complete a
  # real passkey assertion before calling the production administrator action.
  # An expired or revoked authority MUST fail closed without a result receipt.
  @spec actor!(manifest(), String.t()) :: User.t()
  def actor!(manifest, role) when role in ["admin_a", "admin_b", "target"] do
    account = decode_account!(manifest[role])
    actor = login!(account.email)
    true = actor.id == account.id
    verify!(actor, account.key)
    actor
  end

  @spec elevated_admin!(manifest()) :: User.t()
  defp elevated_admin!(manifest), do: actor!(manifest, "admin_a")

  @spec refresh_repository(String.t(), String.t()) :: :ok
  defp refresh_repository(path, result_path) do
    manifest = read_manifest!(path)
    actor = elevated_admin!(manifest)
    {:ok, repo} = Catalog.refresh(actor, manifest["repository_id"])

    write_private!(result_path, %{
      "version" => 1,
      "status" => "applied",
      "operation" => "refresh_repository",
      "repository_id" => repo.id
    })
  end

  @spec demote_admin_b(String.t(), String.t()) :: :ok
  defp demote_admin_b(path, result_path) do
    manifest = read_manifest!(path)
    actor = elevated_admin!(manifest)
    admin_b = decode_account!(manifest["admin_b"])

    {:ok, %{administrator: false}} =
      User
      |> Ash.ActionInput.for_action(
        :set_administrator,
        %{user_id: admin_b.id, administrator: false},
        actor: actor
      )
      |> Ash.run_action()

    write_private!(result_path, %{
      "version" => 1,
      "status" => "applied",
      "operation" => "demote_admin_b",
      "user_id" => admin_b.id
    })
  end

  @spec write_private!(String.t(), map()) :: :ok
  def write_private!(path, data) do
    temporary = path <> ".new"
    :ok = File.write(temporary, JSON.encode!(data))
    :ok = File.chmod(temporary, 0o600)
    :ok = File.rename(temporary, path)
  end
end
