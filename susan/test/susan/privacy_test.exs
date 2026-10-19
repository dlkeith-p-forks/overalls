defmodule Susan.PrivacyTest do
  use Susan.DataCase, async: false

  alias Susan.{FakeProvider, Poke}
  alias Susan.Repo

  @tables ~w(audit_entries delivery_receipts install_identities key_denials unregistered_tokens oban_jobs)

  test "events carry only enum and integer metadata" do
    for {_name, spec} <- Susan.Events.__catalog__(), {_key, type} <- spec.metadata do
      base =
        if match?({_, :optional}, type) and not match?({:enum, _}, type),
          do: elem(type, 0),
          else: type

      assert match?({:enum, _}, base) or base in [:int, :int64],
             "unexpected metadata type #{inspect(type)}"
    end
  end

  test "no token, push key, ciphertext, nonce, deployment or source survives in the database" do
    config = Fixtures.config()
    {push_key, key} = Fixtures.push_key(config)
    source = :crypto.strong_rand_bytes(32)
    nonce = :crypto.strong_rand_bytes(16)
    input = Fixtures.poke(push_key, Fixtures.install(), source: source, nonce: nonce)
    FakeProvider.script([{"https://api.push.apple.com", 410, [], ~s({"reason":"Unregistered"})}])
    assert {:respond, 410, _, _} = Poke.handle(input, config)
    assert {:respond, 410, _, _} = Poke.handle(input, config)

    dump =
      Enum.map_join(@tables, "\n", fn table ->
        %{rows: rows} = Repo.query!("SELECT row_to_json(t)::text FROM #{table} t", [])
        Enum.map_join(rows, "\n", &hd/1)
      end)

    body = JSON.decode!(input.body)

    for secret <- [
          key.token,
          push_key,
          body["ciphertext"],
          body["nonce"],
          Fixtures.deployment(),
          Base.encode16(source, case: :lower),
          Base.url_encode64(source)
        ] do
      refute dump =~ secret
    end

    assert dump =~ body["delivery_id"]
  end

  test "the privacy filter replaces uncatalogued log text with a fixed message" do
    event = %{level: :error, msg: {:string, "token=secret"}, meta: %{}}

    assert %{msg: {:string, "Susan runtime diagnostic (payload redacted)"}} =
             Susan.Privacy.filter(event, nil)
  end
end
