defmodule Audi.DNS.DirectoryTest do
  use ExUnit.Case, async: true
  use ExUnitProperties
  alias Audi.DNS.Directory

  property "publication order cannot roll back the highest accepted revision" do
    check all(revisions <- list_of(integer(0..1000), min_length: 1, max_length: 80)) do
      directory = Audi.Test.DNSDirectory.start!()
      expires = System.monotonic_time(:millisecond) + 60_000

      Enum.reduce(revisions, -1, fn revision, highest ->
        entry = %{
          addresses: [{192, 0, div(revision, 256), rem(revision, 256)}],
          expires_at: expires
        }

        result = Directory.publish(directory, revision, %{"vm.apps.example" => entry}, expires)
        expected = max(revision, highest)
        assert result == if(revision >= highest, do: :ok, else: {:error, :stale})

        assert {:ok, ^expected, %{addresses: [{192, 0, a, b}]}} =
                 Directory.lookup(directory, "vm.apps.example")

        assert 256 * a + b == expected
        expected
      end)
    end
  end

  test "a snapshot with an entry lacking its own deadline is refused whole" do
    directory = Audi.Test.DNSDirectory.start!()
    expires = System.monotonic_time(:millisecond) + 60_000
    live = %{addresses: [{192, 0, 2, 1}], expires_at: expires}
    assert :ok = Directory.publish(directory, 1, %{"live.apps.example" => live}, expires)

    undated = %{"live.apps.example" => live, "vm.apps.example" => %{addresses: [{192, 0, 2, 2}]}}
    assert {:error, :invalid_message} = Directory.publish(directory, 2, undated, expires)
    assert {:ok, 1, ^live} = Directory.lookup(directory, "live.apps.example")
    assert {:ok, 1, nil} = Directory.lookup(directory, "vm.apps.example")
  end
end
