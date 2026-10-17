defmodule Audi.DNS.ChallengeTest do
  use ExUnit.Case, async: true
  use ExUnitProperties
  alias Audi.DNS.{Challenge, Directory}
  @name "_acme-challenge.demo-0123456789abcdef0123456789abcdef.apps.example"

  property "every SHA-256 digest has a valid canonical proof and padded forms are rejected" do
    check all(bytes <- binary(length: 32)) do
      proof = Base.url_encode64(bytes, padding: false)
      entry = %{challenges: [proof], expires_at: 1}
      assert Challenge.valid?(@name, entry)
      refute Challenge.valid?(@name, %{entry | challenges: [proof <> "="]})
      refute Challenge.valid?(@name, %{entry | challenges: [proof, proof]})
    end
  end

  test "invalid proofs or owners cannot replace a valid snapshot" do
    directory = Audi.Test.DNSDirectory.start!([])
    expiry = System.monotonic_time(:millisecond) + 30_000
    proof = Base.url_encode64(<<0::256>>, padding: false)
    entry = %{challenges: [proof], expires_at: expiry}
    assert :ok = Directory.publish(directory, 1, %{@name => entry}, expiry)

    for {name, invalid} <- [
          {"_acme-challenge.apps.example", entry},
          {"other." <> @name, entry},
          {<<255>> <> @name, entry},
          {@name, %{entry | challenges: []}},
          {@name, %{entry | challenges: List.duplicate(proof, 5)}},
          {@name, %{entry | challenges: ["not-a-proof"]}},
          {@name, Map.put(entry, :addresses, [{192, 0, 2, 1}])}
        ] do
      assert {:error, :invalid_challenge} =
               Directory.publish(directory, 2, %{name => invalid}, expiry)

      assert {:ok, 1, ^entry} = Directory.lookup(directory, @name)
    end
  end
end
