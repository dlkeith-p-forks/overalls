defmodule ResizeGuest do
  @moduledoc false
  alias FleetTerminal, as: Terminal

  # @cc [owner:ghuntley,label:verification;storage] resize-native-data-and-shape
  # Probes MUST execute inside the actual current Firecracker boot and verify
  # preexisting guest data, exact block length and CPU count, and grown filesystem.
  # Terminal bytes and exception messages MUST stay inside the disposable fixture.
  @spec run(String.t(), String.t(), pos_integer(), pos_integer()) :: :ok
  def run(mode, placement, cpu, disk) when mode in ["seed", "check"] do
    true = OverallsProtocol.uuid?(placement)
    {:ok, terminal} = Terminal.connect(placement)

    try do
      :ok = Terminal.ready(terminal, 120_000)

      memory_kib = if cpu == 2, do: 768 * 1024, else: 512 * 1024

      command =
        if mode == "seed" do
          "printf 'resize-persistent-fixture\\n' >/root/resize-proof; sync"
        else
          "memory=$(awk '/MemTotal:/ {print $2}' /proc/meminfo) && " <>
            "test \"$(cat /root/resize-proof)\" = resize-persistent-fixture && " <>
            "test \"$(nproc)\" = #{cpu} && " <>
            "test \"$memory\" -gt #{memory_kib - 65_536} && test \"$memory\" -le #{memory_kib} && " <>
            "test \"$(blockdev --getsize64 /dev/vda)\" = #{disk} && " <>
            "test \"$(df -B1 --output=size / | tail -1)\" -gt #{div(disk * 9, 10)}"
        end

      marker = "RESIZE_" <> Base.encode16(:crypto.strong_rand_bytes(12))

      :ok =
        Terminal.write(
          terminal,
          command <> "; result=$?; printf '\\n#{marker}:%s\\n' \"$result\"\n"
        )

      wait(terminal, Regex.compile!("\\n#{marker}:0\\n"), deadline(), "")
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
        raise "Resize fixture terminal closed"
    end
  end
end

try do
  [mode, placement, cpu, disk] = System.argv()
  cpu = String.to_integer(cpu)
  disk = String.to_integer(disk)
  true = cpu in 1..2 and disk in [4_294_967_296, 5_368_713_216, 6_442_450_944]
  :ok = ResizeGuest.run(mode, placement, cpu, disk)
  IO.puts("Resize guest assertions passed")
rescue
  _ ->
    IO.puts(:stderr, "Resize guest assertions failed; terminal bytes withheld")
    System.halt(1)
end
