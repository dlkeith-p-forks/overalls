defmodule FleetBradyGuest do
  @moduledoc false
  alias FleetTerminal, as: Terminal

  # @cc [owner:ghuntley,label:verification;security] brady-real-guest-egress
  # Requests MUST execute in the real guest console. Only fixed actions and a
  # validated placement select commands. Console bytes and TLS data MUST NOT be
  # included in diagnostics; the certificate is a generated test trust anchor.
  def run(action, placement) do
    true = OverallsProtocol.uuid?(placement)

    curl =
      "curl --noproxy '*' --silent --fail --max-time 10 --resolve origin.brady.test:80:11.0.0.1 --resolve origin.brady.test:443:11.0.0.1"

    check =
      case action do
        "retained" ->
          "test \"$(#{curl} --local-port 42001 http://origin.brady.test/public)\" = isolated-brady-origin"

        "reused" ->
          "test \"$(#{curl} --local-port 42002 http://origin.brady.test/public)\" = isolated-brady-origin"

        "http" ->
          "test \"$(#{curl} http://origin.brady.test/public)\" = isolated-brady-origin"

        "tls" ->
          ca = File.read!("/var/lib/overalls-fleet/brady-ca.pem") |> Base.encode64()

          "printf %s #{ca} | base64 -d > /root/brady-ca.pem && test \"$(#{curl} --cacert /root/brady-ca.pem https://origin.brady.test/public)\" = isolated-brady-origin"

        "denied" ->
          "#{curl} http://origin.brady.test/public >/dev/null; test $? = 28"

        "secret" ->
          "test \"$(#{curl} -H 'Authorization: Bearer brady-fleet-secret' 'http://origin.brady.test/private?signature=brady-fleet-signature')\" = isolated-brady-origin"
      end

    {:ok, socket} = Terminal.connect(placement)

    try do
      :ok = Terminal.ready(socket, 120_000)
      marker = "BRADY_" <> Base.encode16(:crypto.strong_rand_bytes(12))
      :ok = Terminal.write(socket, "(#{check}) && printf '\\n#{marker}:OK\\n'\n")
      wait(socket, "\n#{marker}:OK\n", deadline(30_000), "")
    after
      Terminal.close(socket)
    end

    :ok
  end

  defp wait(socket, marker, until, tail) do
    true = System.monotonic_time(:millisecond) < until

    case Terminal.read(socket, 1000) do
      {:ok, bytes} ->
        body = :binary.replace(tail <> bytes, "\r", "", [:global])

        if :binary.match(body, marker) == :nomatch do
          count = min(byte_size(body), byte_size(marker))
          wait(socket, marker, until, binary_part(body, byte_size(body) - count, count))
        end

      {:error, :timeout} ->
        wait(socket, marker, until, tail)

      _ ->
        raise "guest console unavailable"
    end
  end

  defp deadline(ms), do: System.monotonic_time(:millisecond) + ms
end

try do
  [action, placement] = System.argv()
  :ok = FleetBradyGuest.run(action, placement)
  IO.puts("Brady guest assertion passed")
rescue
  _ ->
    IO.puts(:stderr, "Brady guest assertion failed; console content withheld")
    System.halt(1)
end
