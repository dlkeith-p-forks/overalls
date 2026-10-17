defmodule Lilly.VM.GuestTrustTransportTest do
  use ExUnit.Case, async: true
  alias Lilly.VM.GuestTrust
  @placement "11111111-1111-4111-8111-111111111111"
  @boot_id "22222222-2222-4222-8222-222222222222"
  @boot %{
    placement_id: @placement,
    execution_epoch: 7,
    generation: 2,
    boot_challenge: String.duplicate("a", 64)
  }

  defp server(reply) do
    root =
      Path.join(
        System.tmp_dir!(),
        "guest-trust-" <> Base.encode16(:crypto.strong_rand_bytes(12), case: :lower)
      )

    File.mkdir!(root)
    path = Path.join(root, "v.sock")

    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, active: false, ip: {:local, path}, packet: :line])

    task =
      Task.async(fn ->
        {:ok, socket} = :gen_tcp.accept(listener)

        try do
          assert {:ok, "CONNECT 1030\n"} = :gen_tcp.recv(socket, 0, 1000)
          :ok = :gen_tcp.send(socket, "OK 1030\n")
          :ok = :inet.setopts(socket, packet: 4)
          assert {:ok, bytes} = :gen_tcp.recv(socket, 0, 1000)
          request = JSON.decode!(bytes)
          assert request["roots"] == ["root-a", "root-b"]
          :ok = :gen_tcp.send(socket, JSON.encode!(reply.(request)))
        after
          :gen_tcp.close(socket)
        end
      end)

    on_exit(fn ->
      :gen_tcp.close(listener)
      File.rm_rf!(root)
    end)

    {path, task}
  end

  test "four-byte frames bind nonce, digest and exact boot" do
    {path, task} =
      server(fn request ->
        Map.take(
          request,
          ~w(version placement_id execution_epoch boot_challenge nonce bundle_digest)
        )
        |> Map.merge(%{"state" => "installed", "boot_id" => @boot_id})
      end)

    assert {:ok, @boot_id, digest} = GuestTrust.deliver(path, @boot, ["root-a", "root-b"], 1000)
    assert digest == GuestTrust.digest(["root-b", "root-a"])
    Task.await(task)
  end

  test "a stale boot receipt is never accepted" do
    {path, task} =
      server(fn request ->
        Map.take(
          request,
          ~w(version placement_id execution_epoch boot_challenge nonce bundle_digest)
        )
        |> Map.merge(%{"state" => "installed", "boot_id" => @boot_id, "execution_epoch" => 8})
      end)

    assert {:error, :trust_unconfirmed} =
             GuestTrust.deliver(path, @boot, ["root-a", "root-b"], 150)

    Task.await(task)
  end
end
