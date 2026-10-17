defmodule Audi.PrivateGuardTest do
  use ExUnit.Case, async: true
  @uuid "11111111-1111-4111-8111-111111111111"
  @binding %{"vm_id" => @uuid, "host_id" => @uuid, "placement_id" => @uuid}

  # A request process that, like Audi's front, owns the subscription socket it
  # hands to the guard; the test keeps the other end, standing in for Lilly.
  defp request(stop? \\ false) do
    parent = self()
    path = Path.join(System.tmp_dir!(), "agt-#{System.unique_integer([:positive])}.sock")
    {:ok, listener} = :gen_tcp.listen(0, [:binary, ifaddr: {:local, path}, active: false])

    owner =
      spawn(fn ->
        {:ok, client} = :gen_tcp.connect({:local, path}, 0, [:binary, active: false], 1000)
        guard = Audi.Private.Guard.start(client, @binding)
        if stop?, do: Audi.Private.Guard.stop(guard)
        send(parent, :started)
        Process.sleep(:infinity)
      end)

    {:ok, server} = :gen_tcp.accept(listener, 1000)
    :gen_tcp.close(listener)
    File.rm(path)
    assert_receive :started, 1000
    {owner, server}
  end

  # @cc [owner:ghuntley,label:verification;security] audi-guard-event-fence
  # The guard MUST kill its request when Lilly revokes (any frame) or the
  # subscription closes, and MUST close the subscription without fencing when
  # the request finishes normally.
  test "a revocation frame fences the request at once" do
    {owner, server} = request()
    ref = Process.monitor(owner)
    :ok = :gen_tcp.send(server, "revoked")
    assert_receive {:DOWN, ^ref, :process, ^owner, :killed}, 500
  end

  test "the subscription closing fences the request" do
    {owner, server} = request()
    ref = Process.monitor(owner)
    :gen_tcp.close(server)
    assert_receive {:DOWN, ^ref, :process, ^owner, :killed}, 500
  end

  test "finishing the request closes the subscription without fencing" do
    {owner, server} = request(true)
    ref = Process.monitor(owner)
    assert {:error, :closed} = :gen_tcp.recv(server, 0, 1000)
    refute_receive {:DOWN, ^ref, :process, ^owner, _}, 200
    Process.exit(owner, :kill)
  end
end
