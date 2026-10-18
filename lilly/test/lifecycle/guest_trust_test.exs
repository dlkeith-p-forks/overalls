defmodule Lilly.Lifecycle.GuestTrustTest do
  use ExUnit.Case, async: true
  import Hegel
  import Hegel.Gen
  alias Lilly.Host.Lock
  alias Lilly.Lifecycle.{GuestTrust, Journal}
  @moduletag :tmp_dir

  setup %{tmp_dir: root} do
    File.chmod!(root, 0o700)

    %{
      root: root,
      payload: %{
        "state" => "pending",
        "host_id" => Lilly.UUID.generate(),
        "placement_id" => Lilly.UUID.generate(),
        "execution_epoch" => 1,
        "generation" => 1,
        "boot_challenge" => String.duplicate("a", 64),
        "boot_id" => nil,
        "bundle_digest" => nil,
        "attempts" => 0
      }
    }
  end

  test "a boot must pass pending and delivering before installed", c do
    check all(attempts <- integer(1..3), max_runs: 12) do
      directory = Path.join(c.root, Lilly.UUID.generate())
      {:ok, lock} = Lock.acquire(directory)

      try do
        assert :ok = Journal.write(GuestTrust, directory, "guest-trust.json", c.payload)

        assert {:error, _} =
                 Journal.write(GuestTrust, directory, "guest-trust.json", %{
                   c.payload
                   | "state" => "installed"
                 })

        Enum.each(1..attempts, fn attempt ->
          assert :ok =
                   Journal.write(GuestTrust, directory, "guest-trust.json", %{
                     c.payload
                     | "state" => "delivering",
                       "attempts" => attempt
                   })

          assert :ok =
                   Journal.write(GuestTrust, directory, "guest-trust.json", %{
                     c.payload
                     | "state" => "failed",
                       "attempts" => attempt
                   })
        end)

        assert :ok =
                 Journal.write(GuestTrust, directory, "guest-trust.json", %{
                   c.payload
                   | "state" => "delivering",
                     "attempts" => attempts + 1
                 })

        assert :ok =
                 Journal.write(GuestTrust, directory, "guest-trust.json", %{
                   c.payload
                   | "state" => "installed",
                     "attempts" => attempts + 1,
                     "boot_id" => Lilly.UUID.generate(),
                     "bundle_digest" => String.duplicate("b", 64)
                 })

        assert {:ok, %{state: :installed, revision: revision}} =
                 Journal.load(GuestTrust, directory, "guest-trust.json")

        assert revision == 2 * attempts + 3
      after
        Lock.release(lock)
      end
    end
  end

  property "digest is invariant under CA ordering and changes when a CA changes" do
    check all(
            left <- binary(min_length: 1, max_length: 64),
            right <- binary(min_length: 1, max_length: 64),
            max_runs: 30
          ) do
      Hegel.assume(left != right)

      assert Lilly.VM.GuestTrust.digest([left, right]) ==
               Lilly.VM.GuestTrust.digest([right, left])

      refute Lilly.VM.GuestTrust.digest([left]) == Lilly.VM.GuestTrust.digest([right])
    end
  end

  test "an agentless boot records trust as skipped at once and the skip stays terminal", c do
    directory = Path.join(c.root, Lilly.UUID.generate())
    {:ok, lock} = Lock.acquire(directory)

    try do
      skipped = %{c.payload | "state" => "skipped"}
      assert :ok = Journal.write(GuestTrust, directory, "guest-trust.json", skipped)
      assert :ok = Journal.write(GuestTrust, directory, "guest-trust.json", skipped)

      for state <- ~w(pending delivering installed failed) do
        assert {:error, _} =
                 Journal.write(GuestTrust, directory, "guest-trust.json", %{
                   c.payload
                   | "state" => state
                 })
      end

      assert {:ok, %{state: :skipped, revision: 1}} =
               Journal.load(GuestTrust, directory, "guest-trust.json")
    after
      Lock.release(lock)
    end
  end

  test "a pending record may still be skipped, and never installed afterwards", c do
    directory = Path.join(c.root, Lilly.UUID.generate())
    {:ok, lock} = Lock.acquire(directory)

    try do
      assert :ok = Journal.write(GuestTrust, directory, "guest-trust.json", c.payload)

      assert :ok =
               Journal.write(GuestTrust, directory, "guest-trust.json", %{
                 c.payload
                 | "state" => "skipped"
               })

      assert {:error, _} =
               Journal.write(GuestTrust, directory, "guest-trust.json", %{
                 c.payload
                 | "state" => "delivering",
                   "attempts" => 1
               })
    after
      Lock.release(lock)
    end
  end
end
