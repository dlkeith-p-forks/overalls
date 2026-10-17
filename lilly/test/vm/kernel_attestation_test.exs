defmodule Lilly.VM.KernelAttestationTest do
  use ExUnit.Case, async: true
  alias Lilly.VM.KernelAttestation

  @placement "11111111-1111-4111-8111-111111111111"
  @boot "22222222-2222-4222-8222-222222222222"
  @challenge String.duplicate("a", 64)
  @digest String.duplicate("b", 64)
  @expected %{
    placement_id: @placement,
    execution_epoch: 9,
    boot_challenge: @challenge,
    os: :freebsd,
    kernel_sha256: @digest
  }

  defp server(response, handshake \\ "OK 1098\n") do
    root =
      Path.join(
        System.tmp_dir!(),
        "kernel-attestation-" <> Base.encode16(:crypto.strong_rand_bytes(12), case: :lower)
      )

    File.mkdir!(root)
    path = Path.join(root, "v.sock")

    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, active: false, ip: {:local, path}, packet: :line])

    task =
      Task.async(fn ->
        {:ok, socket} = :gen_tcp.accept(listener)

        try do
          assert {:ok, "CONNECT 1098\n"} = :gen_tcp.recv(socket, 0, 2_000)
          :ok = :gen_tcp.send(socket, handshake <> response)
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

  defp wire do
    JSON.encode!(%{
      "version" => 1,
      "state" => "attested",
      "os" => "freebsd",
      "placement_id" => @placement,
      "execution_epoch" => 9,
      "boot_challenge" => @challenge,
      "boot_id" => @boot,
      "kernel_sha256" => @digest
    }) <> "\n"
  end

  test "native probe verifies host CID-bound response and allows fragmentation" do
    {path, task} = server(wire())
    assert {:ok, @boot} = KernelAttestation.verify(path, @expected, 1_000)
    Task.await(task)
  end

  test "wrong OS, digest, boot and malformed frames fail closed" do
    for change <- [
          %{"os" => "illumos"},
          %{"kernel_sha256" => String.duplicate("c", 64)},
          %{"boot_challenge" => String.duplicate("c", 64)},
          %{"boot_id" => "not-a-uuid"},
          %{"unexpected" => true}
        ] do
      value =
        %{
          "version" => 1,
          "state" => "attested",
          "os" => "freebsd",
          "placement_id" => @placement,
          "execution_epoch" => 9,
          "boot_challenge" => @challenge,
          "boot_id" => @boot,
          "kernel_sha256" => @digest
        }
        |> Map.merge(change)
        |> JSON.encode!()
        |> then(&(&1 <> "\n"))

      {path, task} = server(value)

      assert {:error, :kernel_attestation_timeout} =
               KernelAttestation.verify(path, @expected, 120)

      Task.await(task)
    end
  end

  test "invalid request is rejected before connecting" do
    assert {:error, :invalid_kernel_attestation_request} =
             KernelAttestation.verify("relative.sock", @expected, 100)
  end
end
