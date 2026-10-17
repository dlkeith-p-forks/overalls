defmodule FleetSSHBootstrapGuest do
  alias FleetTerminal, as: Terminal

  # @cc [owner:ghuntley,label:verification;security] bootstrap-native-guest-probes
  # Check real guest services and durable account/file ownership through the
  # fixture console. Only seed may write a fixed data marker; no mode starts
  # SSH or roster units, installs authority, or prints console contents.
  @spec run(String.t(), String.t(), String.t()) :: :ok
  def run(mode, placement, username) do
    true = mode in ["seed", "check", "blocked"]
    true = OverallsProtocol.uuid?(placement)
    true = Regex.match?(~r/\A[a-z][a-z0-9_-]{0,30}\z/, username)
    IO.puts(:stderr, "Bootstrap fixture stage: connect")
    {:ok, socket} = connect(placement, System.monotonic_time(:millisecond) + 30_000)

    try do
      :ok = Terminal.ready(socket, 30_000)
      IO.puts(:stderr, "Bootstrap fixture stage: service-and-data-check")
      home = "/home/#{username}"

      check =
        if mode == "blocked" do
          "! systemctl is-active --quiet sshd.service && ! systemctl is-active --quiet ssh.service"
        else
          seed =
            if mode == "seed",
              do:
                "printf bootstrap-data >#{home}/bootstrap-data && chown #{username} #{home}/bootstrap-data && ",
              else: ""

          "timeout 30 sh -c 'until systemctl is-active --quiet sshd.service || systemctl is-active --quiet ssh.service; do sleep .2; done' && " <>
            "test -d #{home} && " <>
            seed <>
            "test $(cat #{home}/bootstrap-data) = bootstrap-data && " <>
            "test $(stat -c %u #{home}/bootstrap-data) = $(id -u #{username})"
        end

      marker = "BOOTSTRAP_" <> Base.encode16(:crypto.strong_rand_bytes(12), case: :lower)

      :ok =
        Terminal.write(
          socket,
          "(#{check}) >/dev/null 2>&1 && printf '\\n%s%s\\n' #{marker} _OK\n"
        )

      wait(socket, marker <> "_OK", System.monotonic_time(:millisecond) + 45_000, "")
    after
      Terminal.close(socket)
    end
  end

  @spec connect(String.t(), integer()) :: {:ok, Terminal.t()}
  defp connect(placement, deadline) do
    result =
      try do
        Terminal.connect(placement)
      rescue
        _ -> :unavailable
      end

    case result do
      {:ok, socket} ->
        {:ok, socket}

      :unavailable ->
        true = System.monotonic_time(:millisecond) < deadline

        receive do
        after
          200 -> connect(placement, deadline)
        end
    end
  end

  @spec wait(Terminal.t(), String.t(), integer(), binary()) :: :ok
  defp wait(socket, marker, deadline, tail) do
    true = System.monotonic_time(:millisecond) < deadline

    case Terminal.read(socket, 1000) do
      {:ok, bytes} ->
        data = tail <> bytes

        if String.contains?(data, marker),
          do: :ok,
          else:
            wait(
              socket,
              marker,
              deadline,
              binary_part(data, max(byte_size(data) - 8192, 0), min(byte_size(data), 8192))
            )

      {:error, :timeout} ->
        wait(socket, marker, deadline, tail)

      _ ->
        raise "Bootstrap fixture console unavailable"
    end
  end
end

try do
  [mode, placement, username] = System.argv()
  :ok = FleetSSHBootstrapGuest.run(mode, placement, username)
  IO.puts("Bootstrap guest check passed")
rescue
  _ ->
    IO.puts(:stderr, "Bootstrap guest check failed; console content withheld")
    System.halt(1)
end
