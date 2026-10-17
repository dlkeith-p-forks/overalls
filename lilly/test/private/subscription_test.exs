defmodule Lilly.Private.SubscriptionTest do
  use ExUnit.Case, async: true
  alias Lilly.Execution
  alias OverallsProtocol.PrivateServices
  @host "11111111-1111-4111-8111-111111111111"
  @placement "22222222-2222-4222-8222-222222222222"

  defp command(generation \\ 1) do
    %{
      id: "33333333-3333-4333-8333-333333333333",
      host_id: @host,
      vm_id: @placement,
      placement_id: @placement,
      execution_epoch: 1,
      generation: generation,
      kind: :start,
      profile: :standard,
      slot: 2
    }
  end

  defp writer, do: spawn(fn -> loop() end)

  defp loop do
    receive do
      {:run, from, fun} ->
        send(from, {:done, self(), fun.()})
        loop()
    end
  end

  defp run(pid, fun) do
    send(pid, {:run, self(), fun})
    assert_receive {:done, ^pid, result}, 1000
    result
  end

  defp later(ms \\ 60_000), do: System.monotonic_time(:millisecond) + ms

  setup do
    # Same pattern as the ingress tests: a private directory under the system temp.
    dir = Path.join(System.tmp_dir!(), "lps-" <> Lilly.UUID.generate())
    File.mkdir!(dir)
    File.chmod!(dir, 0o700)
    on_exit(fn -> File.rm_rf!(dir) end)
    view = :"subscription_view_#{System.unique_integer([:positive])}"
    start_supervised!({OverallsProtocol.View, name: view})
    runtime = writer()
    actor = writer()
    :ok = run(runtime, fn -> Execution.runtime_connected(view) end)
    :ok = run(runtime, fn -> Execution.intent(view, command()) end)
    {:ok, %{uid: uid}} = File.stat("/proc/self")
    path = Path.join(dir, "private.sock")

    start_supervised!(
      {Lilly.Private.Server, path: path, audi_uid: uid, host_id: @host, view: view}
    )

    %{view: view, runtime: runtime, actor: actor, path: path}
  end

  defp subscribe(ctx, purpose \\ :services) do
    {:ok, socket} =
      :gen_tcp.connect({:local, ctx.path}, 0, [:binary, active: false, packet: 4], 1000)

    :ok = :gen_tcp.send(socket, JSON.encode!(PrivateServices.watch_request("10.20.0.2", purpose)))

    case :gen_tcp.recv(socket, 0, 1000) do
      {:ok, bytes} ->
        {:ok, reply} = JSON.decode(bytes)
        {PrivateServices.decode_grant(reply, purpose), socket}

      other ->
        {other, socket}
    end
  end

  defp revoked?(socket, timeout) do
    case :gen_tcp.recv(socket, 0, timeout) do
      {:ok, bytes} -> PrivateServices.revocation?(JSON.decode!(bytes))
      {:error, :closed} -> true
      {:error, :timeout} -> false
    end
  end

  # @cc [owner:ghuntley,label:verification;security] private-subscription-event-revocation
  # A granted subscription MUST be revoked on the event that ends its proof
  # (row withdrawn, intent superseded, runtime disconnected, deadline), and
  # MUST NOT be revoked by an identical renewal.
  test "a current execution is granted, and withdrawing its proof revokes at once", ctx do
    :ok =
      run(ctx.actor, fn -> Execution.publish(ctx.view, :live, command(), {:e, :c}, later()) end)

    {{:ok, binding}, socket} = subscribe(ctx)
    assert binding["placement_id"] == @placement

    # An identical renewal (new deadline) keeps the subscription.
    :ok =
      run(ctx.actor, fn -> Execution.publish(ctx.view, :live, command(), {:e, :c}, later()) end)

    refute revoked?(socket, 100)

    :ok = run(ctx.actor, fn -> Execution.withdraw(ctx.view, :live, @placement) end)
    assert revoked?(socket, 500)
  end

  test "a superseding intent and a disconnected runtime revoke", ctx do
    :ok =
      run(ctx.actor, fn -> Execution.publish(ctx.view, :live, command(), {:e, :c}, later()) end)

    {{:ok, _}, first} = subscribe(ctx)
    :ok = run(ctx.runtime, fn -> Execution.intent(ctx.view, command(2)) end)
    assert revoked?(first, 500)

    :ok = run(ctx.runtime, fn -> Execution.intent(ctx.view, command()) end)
    {{:ok, _}, second} = subscribe(ctx)
    :ok = run(ctx.runtime, fn -> Execution.runtime_disconnected(ctx.view) end)
    assert revoked?(second, 500)
  end

  test "the proof deadline revokes without any further event", ctx do
    :ok =
      run(ctx.actor, fn ->
        Execution.publish(ctx.view, :live, command(), {:e, :c}, later(2_000))
      end)

    # The margin keeps a slow subscribe on a loaded host from reaching the
    # deadline before the refutation; the deadline alone must still revoke.
    {{:ok, _}, socket} = subscribe(ctx)
    refute revoked?(socket, 100)
    assert revoked?(socket, 5_000)
  end

  test "roster purposes need only the boot row; services need the live row", ctx do
    :ok =
      run(ctx.actor, fn -> Execution.publish(ctx.view, :boot, command(), {:e, :c}, later()) end)

    {{:ok, roster}, _socket} = subscribe(ctx, :ssh_roster)
    assert roster["operation_id"] == command().id
    {refused, _socket} = subscribe(ctx, :services)
    refute match?({:ok, _}, refused)
  end

  test "a malformed request is refused before any grant", ctx do
    {:ok, socket} =
      :gen_tcp.connect({:local, ctx.path}, 0, [:binary, active: false, packet: 4], 1000)

    :ok = :gen_tcp.send(socket, JSON.encode!(%{"version" => 1, "address" => "10.20.0.2"}))
    assert {:error, :closed} = :gen_tcp.recv(socket, 0, 2500)
  end
end
