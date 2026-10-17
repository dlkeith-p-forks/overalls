defmodule Audi.SSH.KeyPublisherTest do
  use ExUnit.Case, async: false
  use ExUnitProperties

  @host "11111111-1111-4111-8111-111111111111"
  @fixtures Path.expand("../../marshall/test/fixtures/tls", __DIR__)

  # @cc [owner:ghuntley,label:verification;protocol] audi-host-key-version-halt-history
  # Transient publication failures may retry; verified 426 MUST halt queued
  # publication while preserving the exact local key-file digests.
  property "host key publisher halts after version refusal and preserves key files", context do
    server =
      start_supervised!(
        {Bandit,
         plug: {Audi.Test.DNSControl, owner: self()},
         scheme: :https,
         ip: {127, 0, 0, 1},
         port: 0,
         startup_log: false,
         certfile: Path.join(@fixtures, "localhost.pem"),
         keyfile: Path.join(@fixtures, "localhost.key")}
      )

    {:ok, {_, port}} = ThousandIsland.listener_info(server)

    {:ok, client} =
      Audi.Control.Client.new(
        "https://127.0.0.1:#{port}",
        "audi_service_" <> String.duplicate("a", 43),
        :gateway,
        host_id: @host,
        cacertfile: Path.join(@fixtures, "ca.pem")
      )

    client = Audi.Test.DNSControl.connected(client)

    before = key_digests(context.directory)

    check all(transients <- member_of([0, 1, 2]), max_runs: 3) do
      publisher =
        start_supervised!(
          {Audi.SSH.KeyPublisher, client: client, host_key_dir: context.directory}
        )

      try do
        for _ <- List.duplicate(:transient, transients) do
          assert_receive {:control_request, pid, ref, _, _, _}, 4000
          send(pid, {ref, 503, "{}"})
          _ = :sys.get_state(publisher)
          send(publisher, :publish)
        end

        assert_receive {:control_request, pid, ref, _, _, _}, 4000
        send(pid, {ref, 426, "invalid version body"})
        _ = :sys.get_state(publisher)
        for _ <- 1..3, do: send(publisher, :publish)
        _ = :sys.get_state(publisher)
        refute_receive {:control_request, _, _, _, _, _}, 300
        assert :sys.get_state(publisher).last == {:error, :unsupported_version}
        refute Audi.SSH.KeyPublisher.automatic_work_enabled?(publisher)
        assert key_digests(context.directory) == before
      after
        stop_supervised(Audi.SSH.KeyPublisher)
      end
    end
  end

  @spec key_digests(binary()) :: %{binary() => binary()}
  defp key_digests(directory) do
    Map.new(File.ls!(directory), fn name ->
      {name, :crypto.hash(:sha256, File.read!(Path.join(directory, name)))}
    end)
  end

  setup do
    directory =
      Path.join(System.tmp_dir!(), "audi-key-publisher-#{System.unique_integer([:positive])}")

    File.mkdir_p!(directory)
    on_exit(fn -> File.rm_rf!(directory) end)

    {_, 0} =
      System.cmd("ssh-keygen", [
        "-q",
        "-t",
        "ed25519",
        "-N",
        "",
        "-f",
        Path.join(directory, "ssh_host_ed25519_key")
      ])

    token = "audi_service_" <> String.duplicate("a", 43)

    {:ok, client} =
      Audi.Control.Client.new("https://127.0.0.1:1", token, :gateway, host_id: @host)

    %{client: client, directory: directory}
  end

  test "a completed publication attempt retains state for the bounded retry", context do
    publisher =
      start_supervised!(
        {Audi.SSH.KeyPublisher, client: context.client, host_key_dir: context.directory}
      )

    assert %{last: {:error, _}} = await_attempt(publisher, 100)
    assert Process.alive?(publisher)
  end

  defp await_attempt(publisher, remaining) when remaining > 0 do
    case :sys.get_state(publisher) do
      %{last: nil} ->
        Process.sleep(10)
        await_attempt(publisher, remaining - 1)

      state ->
        state
    end
  end

  defp await_attempt(_publisher, 0), do: flunk("publication attempt did not complete")
end
