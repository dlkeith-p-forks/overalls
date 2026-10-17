defmodule Audi.ACME.ObservedTest do
  use ExUnit.Case, async: true
  alias Audi.ACME.Observed
  @id "11111111-1111-4111-8111-111111111111"
  @proof Base.url_encode64(<<0::256>>, padding: false)
  @host "vm-11111111111111111111111111111111.apps.example"
  @input %{
    "binding" => %{
      "placement_id" => @id,
      "execution_epoch" => 1,
      "boot_challenge" => String.duplicate("a", 64)
    },
    "generation" => 2
  }

  setup do
    root = Path.join(System.tmp_dir!(), "audi-proof-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    File.chmod!(root, 0o700)
    on_exit(fn -> File.rm_rf!(root) end)
    {:ok, source} = Observed.new(@input, "apps.example")
    %{source: %{source | path: Path.join(root, "verify.sock"), uid: File.stat!("/proc/self").uid}}
  end

  test "runtime binding cannot choose a peer or socket path" do
    assert {:ok, source} = Observed.new(@input, "apps.example")
    assert source.path == "/run/inception-proofs/verify.sock" and source.uid == 0

    for invalid <- [
          Map.put(@input, "uid", 1000),
          Map.put(@input, "path", "/tmp/other"),
          put_in(@input, ["binding", "execution_epoch"], 0),
          put_in(@input, ["binding", "boot_challenge"], "bad"),
          Map.put(@input, "generation", true)
        ] do
      assert :error = Observed.new(invalid, "apps.example")
    end
  end

  test "the real Unix exchange binds boot, generation and exact proof set", c do
    ref = serve(c.source.path, fn _ -> JSON.encode!(%{version: 1, ttl_ms: 2000}) end)
    assert Observed.ready?(@host, [@proof], c.source)
    assert_receive {^ref, {:ok, request}}

    assert JSON.decode!(request) == %{
             "version" => 1,
             "binding" => @input["binding"],
             "generation" => 2,
             "label" => "vm-11111111111111111111111111111111",
             "proofs" => [@proof]
           }
  end

  test "wrong UID is refused before sending any request", c do
    ref = serve(c.source.path, fn _ -> "{}" end)
    refute Observed.ready?(@host, [@proof], %{c.source | uid: c.source.uid + 1})
    assert_receive {^ref, {:error, :closed}}
  end

  test "delayed replies cannot renew an expired original-request lifetime", c do
    serve(c.source.path, fn _ ->
      Process.sleep(30)
      JSON.encode!(%{version: 1, ttl_ms: 1})
    end)

    refute Observed.ready?(@host, [@proof], c.source)
  end

  test "missing and stalled brokers fail without another transport", c do
    refute Observed.ready?(@host, [@proof], c.source)

    serve(c.source.path, fn _ ->
      Process.sleep(800)
      JSON.encode!(%{version: 1, ttl_ms: 5000})
    end)

    started = System.monotonic_time(:millisecond)
    refute Observed.ready?(@host, [@proof], c.source)
    assert System.monotonic_time(:millisecond) - started < 750
  end

  test "invalid replies and unrelated hostnames grant no readiness", c do
    for response <- [
          %{version: 2, ttl_ms: 1000},
          %{version: 1, ttl_ms: 0},
          %{version: 1, ttl_ms: 5001},
          %{version: 1, ttl_ms: true},
          %{version: 1, ttl_ms: 1000, ready: true},
          %{version: 1, ttl_ms: 1000, padding: String.duplicate("x", 256)}
        ] do
      path = c.source.path <> Integer.to_string(System.unique_integer([:positive]))
      serve(path, fn _ -> JSON.encode!(response) end)
      refute Observed.ready?(@host, [@proof], %{c.source | path: path})
    end

    refute Observed.ready?(@host <> ".other.example", [@proof], c.source)
    refute Observed.ready?("control.apps.example", [@proof], c.source)
  end

  defp serve(path, respond) do
    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, ifaddr: {:local, path}, active: false, packet: 4])

    owner = self()
    ref = make_ref()

    task =
      Task.async(fn ->
        case :gen_tcp.accept(listener, 1000) do
          {:ok, socket} ->
            try do
              result = :gen_tcp.recv(socket, 0, 1000)
              send(owner, {ref, result})
              if match?({:ok, _}, result), do: :gen_tcp.send(socket, respond.(elem(result, 1)))
            after
              :gen_tcp.close(socket)
            end

          _ ->
            :ok
        end
      end)

    on_exit(fn ->
      :gen_tcp.close(listener)
      monitor = Process.monitor(task.pid)
      Process.exit(task.pid, :kill)

      receive do
        {:DOWN, ^monitor, :process, _, _} -> :ok
      after
        1000 -> flunk("proof fixture did not stop")
      end
    end)

    ref
  end
end
