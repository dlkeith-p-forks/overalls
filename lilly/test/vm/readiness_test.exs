defmodule Lilly.VM.ReadinessTest do
  use ExUnit.Case, async: true
  alias Lilly.VM.Readiness
  @placement "11111111-1111-4111-8111-111111111111"
  @boot "22222222-2222-4222-8222-222222222222"
  @challenge String.duplicate("a", 64)
  @expected %{placement_id: @placement, execution_epoch: 9, boot_challenge: @challenge}

  defp wire do
    %{
      "version" => 1,
      "state" => "ready",
      "placement_id" => @placement,
      "execution_epoch" => 9,
      "boot_challenge" => @challenge,
      "boot_id" => @boot
    }
  end

  defp server(callback) do
    root =
      Path.join(
        System.tmp_dir!(),
        "readiness-" <> Base.encode16(:crypto.strong_rand_bytes(12), case: :lower)
      )

    File.mkdir!(root)
    path = Path.join(root, "v.sock")

    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, active: false, ip: {:local, path}, packet: :line])

    task =
      Task.async(fn ->
        {:ok, socket} = :gen_tcp.accept(listener)

        try do
          assert {:ok, "CONNECT 1024\n"} = :gen_tcp.recv(socket, 0, 2000)
          callback.(socket)
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

  test "fragmented handshake and guest frame bind the full expected boot" do
    {path, task} =
      server(fn socket ->
        for fragment <- ["O", "K 1073741824\n", JSON.encode!(wire()), "\n"] do
          :ok = :gen_tcp.send(socket, fragment)
        end
      end)

    assert {:ok, @boot} = Readiness.wait(path, @expected, 1000)
    Task.await(task)
  end

  test "a valid guest probe may take longer than one second within the overall deadline" do
    {path, task} =
      server(fn socket ->
        :ok = :gen_tcp.send(socket, "OK 1234\n")
        Process.sleep(1200)
        :gen_tcp.send(socket, JSON.encode!(wire()) <> "\n")
      end)

    assert {:ok, @boot} = Readiness.wait(path, @expected, 2500)
    Task.await(task)
  end

  test "the forty-minute bound accepts an immediate current-boot response" do
    {path, task} =
      server(fn socket ->
        :ok = :gen_tcp.send(socket, "OK 1234\n" <> JSON.encode!(wire()) <> "\n")
      end)

    assert {:ok, @boot} = Readiness.wait(path, @expected, 2_400_000)
    Task.await(task)
  end

  test "stale placement, epoch and challenge cannot satisfy the readiness deadline" do
    for {field, value} <- [
          {"placement_id", @boot},
          {"execution_epoch", 10},
          {"boot_challenge", String.duplicate("b", 64)}
        ] do
      {path, task} =
        server(fn socket ->
          :gen_tcp.send(
            socket,
            "OK 1234\n" <> JSON.encode!(Map.put(wire(), field, value)) <> "\n"
          )
        end)

      assert {:error, :readiness_timeout} = Readiness.wait(path, @expected, 120)
      Task.await(task)
    end
  end

  test "invalid handshake and oversized guest frame fail closed" do
    for body <- [
          "OK 0\n",
          "OK 01\n",
          "OK 4294967296\n",
          "ERR\n",
          "OK 2\n" <> String.duplicate("x", 513)
        ] do
      {path, task} = server(fn socket -> :gen_tcp.send(socket, body) end)
      assert {:error, :readiness_timeout} = Readiness.wait(path, @expected, 120)
      Task.await(task)
    end
  end

  test "an unresponsive connected guest cannot extend the overall deadline" do
    {path, task} = server(fn _socket -> Process.sleep(250) end)
    started = System.monotonic_time(:millisecond)
    assert {:error, :readiness_timeout} = Readiness.wait(path, @expected, 100)
    elapsed = System.monotonic_time(:millisecond) - started
    assert elapsed >= 90
    assert elapsed < 500
    Task.await(task)
  end

  test "invalid paths, expectations and timeouts are rejected before connecting" do
    for path <- [
          nil,
          <<47, 255>>,
          "relative.sock",
          "/bad" <> <<0>>,
          "/" <> String.duplicate("x", 107)
        ] do
      assert {:error, :invalid_readiness_request} = Readiness.wait(path, @expected, 100)
    end

    for timeout <- [nil, 0, -1, 1.5, 2_400_001] do
      assert {:error, :invalid_readiness_request} =
               Readiness.wait("/no-socket", @expected, timeout)
    end

    for expected <- [
          %{},
          Map.put(@expected, :execution_epoch, 0),
          Map.put(@expected, :boot_challenge, "bad")
        ] do
      assert {:error, :invalid_readiness_request} = Readiness.wait("/no-socket", expected, 100)
    end
  end
end
