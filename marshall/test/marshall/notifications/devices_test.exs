defmodule Marshall.Notifications.DevicesTest do
  use Marshall.DataCase, async: false
  import Hegel
  import Hegel.Gen
  import Marshall.ComputeFixtures
  alias Marshall.{Notifications, SSH}
  alias Marshall.Authorization.SystemActor
  alias Marshall.Compute.Ledger
  alias Marshall.Notifications.{Device, DeviceActions}
  alias Marshall.SSH.{Request, Token}
  alias OverallsProtocol.PushPoke
  require Ash.Query
  @moduletag capture_log: true

  @type device_command ::
          {:register, 0..2}
          | {:remove, 0..2}
          | {:prefs, 0..2, boolean()}
          | :revoke_key

  setup do
    actor = user()
    public_key = public_key(<<1::256>>)
    {:ok, key} = SSH.add_key(%{public_key: public_key}, actor: actor)
    {gateway_token, _} = Token.issue(:gateway)

    {:ok, _} =
      SSH.configure_gateway(%{name: "notify-fixture", token: gateway_token},
        actor: SystemActor.compute()
      )

    {:ok, session} =
      SSH.open_session(%{gateway_token: gateway_token, public_key: public_key},
        actor: SystemActor.compute()
      )

    on_exit(fn -> Application.delete_env(:marshall, :notifications_enabled) end)

    %{
      actor: actor,
      key: key,
      gateway_token: gateway_token,
      session_token: session.session_token
    }
  end

  test "desktop devices register under their own platform", c do
    for platform <- ["macos", "windows"] do
      {enc, _private} = PushPoke.generate_key_pair()

      assert {:ok, %{"status" => "succeeded", "result" => result}} =
               command(c, register_line(enc, "", platform), push_key(platform)) |> stringify()

      assert result["platform"] == platform
      assert [%{platform: atom}] = Ledger.read!(Device, id: result["id"])
      assert Atom.to_string(atom) == platform
    end
  end

  test "device register binds the session key, redacts the push key and lists without secrets",
       c do
    {enc, _private} = PushPoke.generate_key_pair()
    push_key = push_key("first")

    assert {:ok, %{"status" => "succeeded", "request_id" => request_id} = reply} =
             command(c, register_line(enc, "--label 'my phone'"), push_key) |> stringify()

    result = reply["result"]
    assert result["platform"] == "ios"
    assert result["label"] == "my phone"
    assert result["state"] == "active"
    assert result["enabled"] == true
    assert result["key_id"] == c.key.id
    assert result["route"] =~ ~r{\Aoveralls://[^/]+/settings\z}
    refute inspect(reply) =~ push_key
    refute inspect(reply) =~ Base.url_encode64(enc, padding: false)

    [request] = Ledger.read!(Request, request_id: request_id)
    refute inspect(request.command) =~ push_key
    assert request.command["options"]["push-key"] =~ ~r/\Adigest:[0-9a-f]{16}:\d+\z/

    [device] = Ledger.read!(Device, id: result["id"])
    assert device.key_id == c.key.id
    assert device.push_key_digest == Notifications.digest(push_key)
    assert device.enc_public_key == enc
    refute Map.get(device, :push_key) == push_key
    %{push_key: ^push_key} = Ash.load!(device, [:push_key], actor: SystemActor.compute())

    assert {:ok, %{"result" => %{"items" => [listed], "limit" => 10, "push_enabled" => true}}} =
             command(c, "device ls --json") |> stringify()

    assert listed["id"] == device.id
    refute inspect(listed) =~ push_key

    # The shared Mila fixture describes exactly these result members.
    fixture =
      Path.expand("../../../../protocol/test/fixtures/porsche_device_results.json", __DIR__)
      |> File.read!()
      |> Jason.decode!()

    for name <- ["device register", "device prefs", "device rm"] do
      expected = fixture["commands"][name]["response"]
      assert Map.keys(expected) |> Enum.sort() == Map.keys(reply) |> Enum.sort()
      assert Map.keys(expected["result"]) |> Enum.sort() == Map.keys(result) |> Enum.sort()
    end

    [fixture_item] = fixture["commands"]["device ls"]["response"]["result"]["items"]
    assert Map.keys(fixture_item) |> Enum.sort() == Map.keys(listed) |> Enum.sort()

    # The same request id replays the pinned receipt without a second device.
    assert {:ok, %{"result" => ^result}} =
             command(
               c,
               register_line(enc, "--label 'my phone' --request-id #{request_id}"),
               push_key
             )
             |> stringify()

    assert [_] = Ledger.read!(Device, user_id: c.actor.id)
  end

  test "re-registering the same device key refreshes the live row", c do
    {enc, _} = PushPoke.generate_key_pair()
    {:ok, first} = register(c, enc, push_key("one"))
    {:ok, second} = register(c, enc, push_key("two"))
    assert first.id == second.id
    [device] = Ledger.read!(Device, user_id: c.actor.id)
    assert device.push_key_digest == Notifications.digest(push_key("two"))
  end

  test "an eleventh live device is refused with device_limit", c do
    for n <- 1..DeviceActions.limit() do
      {enc, _} = PushPoke.generate_key_pair()
      assert {:ok, _} = register(c, enc, push_key("d#{n}"))
    end

    {enc, _} = PushPoke.generate_key_pair()
    assert {:error, error} = register(c, enc, push_key("extra"))
    assert reason(error) == :device_limit
    assert {:error, 409, "device_limit"} = classify(command(c, register_line(enc), push_key("x")))
  end

  test "push_disabled refuses registration when the operator turned notifications off", c do
    Application.put_env(:marshall, :notifications_enabled, false)
    {enc, _} = PushPoke.generate_key_pair()
    assert {:error, error} = register(c, enc, push_key("off"))
    assert reason(error) == :push_disabled

    assert {:error, 409, "push_disabled"} =
             classify(command(c, register_line(enc), push_key("off")))

    assert [] == Ledger.read!(Device, user_id: c.actor.id)
  end

  test "malformed keys and another account's key id are refused", c do
    {enc, _} = PushPoke.generate_key_pair()
    other = user()
    {:ok, other_key} = SSH.add_key(%{public_key: public_key(<<9::256>>)}, actor: other)

    assert {:error, error} =
             Notifications.register_device(
               %{
                 platform: :ios,
                 push_key: push_key("x"),
                 enc_public_key: b64(enc),
                 key_id: other_key.id
               },
               actor: c.actor
             )

    assert reason(error) == :unauthorized

    for {push, pub} <- [{"short", b64(enc)}, {push_key("x"), "AAAA"}] do
      assert {:error, error} =
               Notifications.register_device(
                 %{platform: :ios, push_key: push, enc_public_key: pub, key_id: c.key.id},
                 actor: c.actor
               )

      assert reason(error) == :invalid_request
    end
  end

  test "prefs and rm are owner-scoped and rm is idempotent", c do
    {enc, _} = PushPoke.generate_key_pair()
    {:ok, device} = register(c, enc, push_key("owned"))

    assert {:ok, %{"result" => %{"enabled" => false}}} =
             command(c, "device prefs #{device.id} --enabled false") |> stringify()

    stranger = user()
    {:ok, _} = SSH.add_key(%{public_key: public_key(<<3::256>>)}, actor: stranger)

    assert {:error, error} = Notifications.remove_device(%{id: device.id}, actor: stranger)
    assert reason(error) == :device_not_found

    assert {:error, error} =
             Notifications.set_device_preference(%{id: device.id, enabled: true}, actor: stranger)

    assert reason(error) == :device_not_found

    assert {:error, 404, "device_not_found"} =
             classify(command(c, "device rm #{Ash.UUID.generate()}"))

    assert {:ok, %{"result" => %{"state" => "revoked"}}} =
             command(c, "device rm #{device.id}") |> stringify()

    assert {:ok, %{state: :revoked}} =
             Notifications.remove_device(%{id: device.id}, actor: c.actor)

    assert [%{state: :revoked, state_reason: :removed}] = Ledger.read!(Device, id: device.id)

    assert {:error, error} =
             Notifications.set_device_preference(%{id: device.id, enabled: true}, actor: c.actor)

    assert reason(error) == :device_not_found
  end

  test "SSH key removal, administrator revocation and account retirement revoke bound devices",
       c do
    {enc, _} = PushPoke.generate_key_pair()
    {:ok, device} = register(c, enc, push_key("bound"))
    {:ok, _} = SSH.remove_key(%{id: c.key.id}, actor: c.actor)
    assert [%{state: :revoked, state_reason: :key_revoked}] = Ledger.read!(Device, id: device.id)

    other_key = public_key(<<4::256>>)
    {:ok, key} = SSH.add_key(%{public_key: other_key}, actor: c.actor)
    {enc2, _} = PushPoke.generate_key_pair()
    {:ok, second} = register(%{c | key: key}, enc2, push_key("second"))

    assert 1 ==
             Ledger.transaction(fn ->
               Notifications.revoke_for_user!(c.actor.id, :account_retired)
             end)
             |> elem(1)

    assert [%{state: :revoked, state_reason: :account_retired}] =
             Ledger.read!(Device, id: second.id)
  end

  test "device versions record transitions with digests only", c do
    {enc, _} = PushPoke.generate_key_pair()
    secret = push_key("audited")
    {:ok, device} = register(c, enc, secret)

    {:ok, _} =
      Notifications.set_device_preference(%{id: device.id, enabled: false}, actor: c.actor)

    {:ok, _} = Notifications.remove_device(%{id: device.id}, actor: c.actor)

    versions =
      Device.Version
      |> Ash.Query.filter(version_source_id == ^device.id)
      |> Ash.read!(actor: SystemActor.compute())

    actions = versions |> Enum.map(& &1.version_action_name) |> Enum.sort()
    assert actions == Enum.sort([:register, :activate, :set_preference, :revoke])
    dump = inspect(versions)
    refute dump =~ secret
    refute dump =~ "encrypted_push_key"
    assert Enum.all?(versions, &(&1.actor_kind == :user and &1.actor_id == c.actor.id))
  end

  # Device lifecycle against a model: live rows never exceed the limit, one
  # live row per device key, revoked rows never return, and SSH key revocation
  # revokes every row bound to it.
  property "device commands match the per-user lifecycle model", test_cases: 40 do
    commands =
      draw(
        "commands",
        list_of(
          one_of([
            tuple({constant(:register), integer(0, 2)}),
            tuple({constant(:remove), integer(0, 2)}),
            tuple({constant(:prefs), integer(0, 2), boolean()}),
            constant(:revoke_key)
          ]),
          min_length: 1,
          max_length: 12
        )
      )

    owner = user()

    {:ok, key} =
      SSH.add_key(%{public_key: public_key(:crypto.strong_rand_bytes(32))}, actor: owner)

    keys = for _ <- 0..2, do: elem(PushPoke.generate_key_pair(), 0)

    Enum.reduce(commands, {%{}, key}, fn command, {model, key} ->
      {model, key} = step(command, model, key, owner, keys)

      live = Ledger.read!(Device, user_id: owner.id) |> Enum.filter(&(&1.state == :active))
      assert Enum.sort(Enum.map(live, & &1.enc_public_key)) == Enum.sort(Map.keys(model))

      for device <- live,
          do: assert(device.enabled == Map.fetch!(model, device.enc_public_key).enabled)

      {model, key}
    end)
  end

  @spec step(device_command(), map(), SSH.Key.t(), Marshall.Accounts.User.t(), [binary()]) ::
          {map(), SSH.Key.t()}
  defp step({:register, index}, model, key, owner, keys) do
    enc = Enum.at(keys, index)

    {:ok, device} =
      Notifications.register_device(
        %{
          platform: :android,
          push_key: push_key("p#{index}"),
          enc_public_key: b64(enc),
          key_id: key.id
        },
        actor: owner
      )

    enabled = if live = model[enc], do: live.enabled, else: true
    assert device.enabled == enabled
    {Map.put(model, enc, %{id: device.id, enabled: enabled}), key}
  end

  defp step({:remove, index}, model, key, owner, keys) do
    enc = Enum.at(keys, index)

    case model[enc] do
      %{id: id} ->
        assert {:ok, %{state: :revoked}} = Notifications.remove_device(%{id: id}, actor: owner)
        {Map.delete(model, enc), key}

      nil ->
        assert {:error, _} = Notifications.remove_device(%{id: Ash.UUID.generate()}, actor: owner)
        {model, key}
    end
  end

  defp step({:prefs, index, enabled}, model, key, owner, keys) do
    enc = Enum.at(keys, index)

    case model[enc] do
      %{id: id} = entry ->
        assert {:ok, %{enabled: ^enabled}} =
                 Notifications.set_device_preference(%{id: id, enabled: enabled}, actor: owner)

        {Map.put(model, enc, %{entry | enabled: enabled}), key}

      nil ->
        {model, key}
    end
  end

  defp step(:revoke_key, model, key, owner, _keys) do
    {:ok, _} = SSH.remove_key(%{id: key.id}, actor: owner)

    for %{id: id} <- Map.values(model),
        do: assert([%{state: :revoked}] = Ledger.read!(Device, id: id))

    {:ok, key} =
      SSH.add_key(%{public_key: public_key(:crypto.strong_rand_bytes(32))}, actor: owner)

    {%{}, key}
  end

  defp register(c, enc, push) do
    Notifications.register_device(
      %{
        platform: :ios,
        push_key: push,
        enc_public_key: b64(enc),
        key_id: c.key.id,
        label: "phone"
      },
      actor: c.actor
    )
  end

  defp register_line(enc, extra \\ "", platform \\ "ios"),
    do:
      "device register --platform #{platform} --push-key - --enc-pubkey #{b64(enc)} --json #{extra}"

  defp command(c, text, push_key \\ nil) do
    {:ok, command} = OverallsProtocol.SSHCommand.parse(String.trim(text))

    command =
      if push_key do
        {:ok, replaced} = OverallsProtocol.SSHCommand.put_stdin_secret(command, push_key)
        replaced
      else
        command
      end

    SSH.execute(
      %{
        gateway_token: c.gateway_token,
        session_token: c.session_token,
        command: command |> Jason.encode!() |> Jason.decode!()
      },
      actor: SystemActor.compute()
    )
  end

  defp stringify({:ok, value}), do: {:ok, value |> Jason.encode!() |> Jason.decode!()}
  defp stringify(other), do: other

  defp classify(result), do: Marshall.SSH.ControlRequests.classify(result)

  defp reason(%{errors: [error]}), do: reason(error)
  defp reason(%{reason: reason}), do: reason
  defp reason(other), do: other

  defp push_key(seed), do: Base.url_encode64(:crypto.hash(:sha256, seed), padding: false)
  defp b64(raw), do: Base.url_encode64(raw, padding: false)

  defp public_key(bytes) do
    blob = <<11::32, "ssh-ed25519", 32::32, bytes::binary>>
    "ssh-ed25519 " <> Base.encode64(blob)
  end
end
