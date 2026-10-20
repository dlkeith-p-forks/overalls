defmodule Susan.PushKeyTest do
  use ExUnit.Case, async: true
  import Hegel
  import Hegel.Gen

  alias Susan.{Fixtures, Keyring, PushKey}

  @fields %{
    provider: :apns,
    environment: :sandbox,
    app_id: "dev.overalls.mila",
    deployment: "control.example.test",
    token: String.duplicate("ab", 32),
    issued_at: 1_792_540_800
  }

  test "a sealed key opens to the same bound fields" do
    {:ok, encoded, key} = PushKey.seal(Fixtures.keyring(), @fields)
    assert {:ok, opened} = PushKey.open(Fixtures.keyring(), encoded, @fields.issued_at + 10)
    assert opened == key
    assert opened.token == @fields.token and opened.deployment == @fields.deployment
    assert byte_size(encoded) <= PushKey.max_encoded()
    refute inspect(key) =~ @fields.token
  end

  test "rotation keeps old keys openable while new keys use the active id" do
    {:ok, old, _} = PushKey.seal(Fixtures.keyring(1), @fields)
    {:ok, new, key} = PushKey.seal(Fixtures.keyring(2), @fields)
    assert key.keyring_id == 2
    assert {:ok, %{keyring_id: 1}} = PushKey.open(Fixtures.keyring(2), old, @fields.issued_at)
    assert {:ok, %{keyring_id: 2}} = PushKey.open(Fixtures.keyring(2), new, @fields.issued_at)
    retired = %Keyring{active: 2, keys: Map.take(Fixtures.keyring(2).keys, [2])}
    assert {:error, :unknown_key} = PushKey.open(retired, old, @fields.issued_at)
  end

  test "keys expire after ninety days and refuse future issue times" do
    {:ok, encoded, _} = PushKey.seal(Fixtures.keyring(), @fields)
    limit = @fields.issued_at + PushKey.lifetime_seconds()
    assert {:ok, _} = PushKey.open(Fixtures.keyring(), encoded, limit)
    assert {:error, :expired_key} = PushKey.open(Fixtures.keyring(), encoded, limit + 1)

    assert {:error, :expired_key} =
             PushKey.open(Fixtures.keyring(), encoded, @fields.issued_at - 301)
  end

  test "garbage never opens and never raises" do
    for value <- ["", "!!!", String.duplicate("A", 701), nil, 7, Base.url_encode64(<<1>>)] do
      assert {:error, :unknown_key} = PushKey.open(Fixtures.keyring(), value, 0)
    end
  end

  @tag :hegel
  test "flipping any bit of an envelope is refused as unknown" do
    {:ok, encoded, _} = PushKey.seal(Fixtures.keyring(), @fields)
    raw = Base.url_decode64!(encoded, padding: false)

    Hegel.check(
      fn ->
        index = draw("byte", integer(0, byte_size(raw) - 1))
        bit = draw("bit", integer(0, 7))
        <<prefix::binary-size(^index), byte, rest::binary>> = raw
        tampered = <<prefix::binary, Bitwise.bxor(byte, Bitwise.bsl(1, bit)), rest::binary>>

        opened =
          PushKey.open(
            Fixtures.keyring(),
            Base.url_encode64(tampered, padding: false),
            @fields.issued_at
          )

        assert opened == {:error, :unknown_key}
      end,
      test_cases: 300
    )
  end

  @tag :hegel
  test "arbitrary bound fields round-trip through the envelope" do
    Hegel.check(
      fn ->
        provider = draw("provider", member_of([:apns, :fcm, :wns]))
        token = draw("token", string(:alphanumeric, min_length: 1, max_length: 200))
        app = draw("app", string(:alphanumeric, min_length: 1, max_length: 60))
        issued = draw("issued", integer(0, 4_000_000_000))
        fields = %{@fields | provider: provider, token: token, app_id: app, issued_at: issued}
        {:ok, encoded, key} = PushKey.seal(Fixtures.keyring(), fields)
        assert {:ok, ^key} = PushKey.open(Fixtures.keyring(), encoded, issued)
      end,
      test_cases: 200
    )
  end
end
