defmodule DefaultOssGuest do
  @moduledoc false
  alias FleetTerminal, as: Terminal

  # @cc [owner:ghuntley,label:verification;security] default-profile-native-egress
  # Profile probes MUST execute fixed DNS/HTTP checks inside the actual current
  # Firecracker boot. OSS MUST reach the live local origin and Customer MUST
  # time out for both direct-IP HTTP and DNS-based HTTP. No terminal bytes or
  # exception messages may leave this disposable privileged probe.
  @spec run(String.t(), String.t()) :: :ok
  def run(profile, placement) when profile in ["oss", "customer"] do
    true = OverallsProtocol.uuid?(placement)
    {:ok, terminal} = Terminal.connect(placement)

    try do
      :ok = Terminal.ready(terminal, 120_000)

      commands =
        if profile == "oss" do
          [
            "test \"$(curl --silent --fail --max-time 10 http://fleet.example.test:8080/)\" = fixture-egress-ok"
          ]
        else
          for address <- ["11.0.0.1", "fleet.example.test"],
              do:
                "curl --silent --connect-timeout 2 --max-time 3 http://#{address}:8080/ -o /dev/null; test \"$?\" = 28"
        end

      for command <- commands do
        marker = "PROFILE_" <> Base.encode16(:crypto.strong_rand_bytes(12))

        :ok =
          Terminal.write(
            terminal,
            command <> "; result=$?; printf '\\n#{marker}:%s\\n' \"$result\"\n"
          )

        wait(terminal, Regex.compile!("\\n#{marker}:0\\n"), deadline(), "")
      end

      :ok
    after
      Terminal.close(terminal)
    end
  end

  @spec deadline() :: integer()
  defp deadline, do: System.monotonic_time(:millisecond) + 120_000

  @spec wait(Terminal.t(), Regex.t(), integer(), binary()) :: :ok
  defp wait(terminal, pattern, until, tail) do
    true = System.monotonic_time(:millisecond) < until

    case Terminal.read(terminal, 1000) do
      {:ok, bytes} ->
        body = String.replace(tail <> bytes, "\r", "")

        if Regex.match?(pattern, body) do
          :ok
        else
          count = min(byte_size(body), 512)
          wait(terminal, pattern, until, binary_part(body, byte_size(body) - count, count))
        end

      {:error, :timeout} ->
        wait(terminal, pattern, until, tail)

      _ ->
        raise "Profile fixture terminal closed"
    end
  end
end

try do
  [profile, placement] = System.argv()
  :ok = DefaultOssGuest.run(profile, placement)
  IO.puts("Profile guest assertions passed")
rescue
  _ ->
    IO.puts(:stderr, "Profile guest assertions failed; terminal bytes withheld")
    System.halt(1)
end
