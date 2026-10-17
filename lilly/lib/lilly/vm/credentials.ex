defmodule Lilly.VM.Credentials do
  @moduledoc "Bounded delivery of an operator-owned SMTP bundle to an Inception boot."
  require Lilly.Events
  alias Lilly.Host.PrivateFiles
  @required ~w(version host port username password from tls)

  # @cc [owner:ghuntley,label:security] inception-host-smtp-source
  # load/1 MUST accept only an operator-owned private runtime file and a closed
  # SMTP schema. Store paths, internal credentials, plaintext SMTP and malformed
  # inputs MUST fail without returning source bytes in errors or diagnostics.
  @spec load(Path.t() | nil) :: {:ok, map()} | {:error, :inception_credentials_unavailable}
  def load(path) when is_binary(path) do
    with true <- valid_path?(path) and not String.starts_with?(path, "/nix/store/"),
         {:ok, bytes} <- PrivateFiles.read_secret(path),
         {:ok, bundle} <- JSON.decode(bytes),
         true <- valid_bundle?(bundle) do
      {:ok, bundle}
    else
      _ -> {:error, :inception_credentials_unavailable}
    end
  end

  def load(_), do: {:error, :inception_credentials_unavailable}

  # @cc [owner:ghuntley,label:security;recovery] inception-host-delivery-bound
  # deliver/4 MUST require a valid current boot binding and bound connection,
  # handshake, delivery and acknowledgment to one deadline. Callers MUST derive
  # the socket from an owned Inception placement and verify current confined
  # execution before and after delivery. Only SMTP is sent; a stale or malformed
  # acknowledgment MUST NOT count as success. No payload may enter diagnostics.
  @spec deliver(
          Path.t(),
          OverallsProtocol.Readiness.expectation(),
          map(),
          pos_integer(),
          OverallsProtocol.uuid() | nil
        ) ::
          :ok | {:error, :inception_credentials_unavailable}
  def deliver(path, expected, bundle, timeout, vm_id \\ nil) do
    with true <- valid_path?(path) and byte_size(path) <= 107,
         true <- is_integer(timeout) and timeout in 1..600_000,
         true <- valid_expected?(expected) and valid_bundle?(bundle),
         binding = Map.new(expected, fn {key, value} -> {Atom.to_string(key), value} end),
         body = JSON.encode!(Map.merge(binding, %{"version" => 1, "smtp" => bundle})) <> "\n",
         true <- byte_size(body) <= 65_536 do
      poll(
        path,
        body,
        Map.merge(binding, %{"version" => 1, "state" => "configured"}),
        now() + timeout,
        vm_id
      )
    else
      _ -> {:error, :inception_credentials_unavailable}
    end
  end

  # @cc [owner:ghuntley,label:security;observability] credential-delivery-events-closed
  # Delivery events MUST carry only the VM identifier, placement, epoch and a
  # closed reason atom. The SMTP bundle, boot challenge, socket path and guest
  # acknowledgment payloads MUST NOT be logged.
  defp poll(path, body, expected, deadline, vm_id) do
    cond do
      remaining(deadline) == 0 ->
        delivery_failed(vm_id, expected)
        {:error, :inception_credentials_unavailable}

      exchange(path, body, expected, deadline) == :ok and remaining(deadline) > 0 ->
        delivered(vm_id, expected)
        :ok

      true ->
        Process.sleep(min(100, remaining(deadline)))
        poll(path, body, expected, deadline, vm_id)
    end
  end

  defp delivered(nil, _expected), do: :ok

  defp delivered(vm_id, expected) do
    if OverallsProtocol.uuid?(vm_id) and OverallsProtocol.uuid?(expected["placement_id"]) do
      Lilly.Events.emit("lilly.vm_credentials_delivered",
        vm_id: vm_id,
        placement_id: expected["placement_id"],
        execution_epoch: expected["execution_epoch"]
      )
    end

    :ok
  end

  defp delivery_failed(nil, _expected), do: :ok

  defp delivery_failed(vm_id, expected) do
    if OverallsProtocol.uuid?(vm_id) and OverallsProtocol.uuid?(expected["placement_id"]) do
      Lilly.Events.emit("lilly.vm_credentials_delivery_failed",
        vm_id: vm_id,
        placement_id: expected["placement_id"],
        reason: :inception_credentials_unavailable
      )
    end

    :ok
  end

  defp exchange(path, body, expected, deadline) do
    options = [:binary, active: false, packet: :line, packet_size: 512, send_timeout_close: true]

    case Lilly.Host.Sockets.connect_local(path, options, remaining(deadline)) do
      {:ok, socket} ->
        try do
          with :ok <- :inet.setopts(socket, send_timeout: remaining(deadline)),
               :ok <- :gen_tcp.send(socket, "CONNECT 1025\n"),
               {:ok, handshake} <- :gen_tcp.recv(socket, 0, remaining(deadline)),
               true <- handshake?(handshake),
               :ok <- :inet.setopts(socket, send_timeout: remaining(deadline)),
               :ok <- :gen_tcp.send(socket, body),
               {:ok, reply} <- :gen_tcp.recv(socket, 0, remaining(deadline)),
               true <- byte_size(reply) <= 512 and String.ends_with?(reply, "\n"),
               {:ok, ^expected} <- JSON.decode(reply) do
            :ok
          else
            _ -> :error
          end
        after
          :gen_tcp.close(socket)
        end

      _ ->
        :error
    end
  end

  defp handshake?("OK " <> suffix) when byte_size(suffix) <= 11 do
    case Integer.parse(suffix) do
      {port, "\n"} when port in 1..4_294_967_295 -> suffix == Integer.to_string(port) <> "\n"
      _ -> false
    end
  end

  defp handshake?(_), do: false

  defp valid_expected?(
         %{placement_id: id, execution_epoch: epoch, boot_challenge: challenge} = value
       )
       when map_size(value) == 3 do
    match?(
      {:ok, _},
      OverallsProtocol.Readiness.response(%{
        "version" => 1,
        "state" => "ready",
        "placement_id" => id,
        "execution_epoch" => epoch,
        "boot_challenge" => challenge,
        "boot_id" => id
      })
    )
  end

  defp valid_expected?(_), do: false

  defp valid_bundle?(bundle) when is_map(bundle) do
    Enum.sort(Map.keys(bundle)) in [Enum.sort(@required), Enum.sort(["ca_pem" | @required])] and
      bundle["version"] === 1 and is_integer(bundle["port"]) and bundle["port"] in 1..65_535 and
      Enum.all?(
        [{"host", 253}, {"username", 1024}, {"password", 4096}, {"from", 254}, {"tls", 8}],
        fn {key, limit} -> text?(bundle[key], limit) end
      ) and
      Regex.match?(~r/\A[A-Za-z0-9][A-Za-z0-9.-]*\z/, bundle["host"]) and
      Regex.match?(~r/\A[^@\s]+@[A-Za-z0-9][A-Za-z0-9.-]*\z/, bundle["from"]) and
      bundle["tls"] in ["implicit", "starttls"] and valid_ca?(bundle)
  end

  defp valid_bundle?(_), do: false

  defp valid_ca?(%{"ca_pem" => pem}) when is_binary(pem) and byte_size(pem) in 1..32_768 do
    try do
      case :public_key.pem_decode(pem) do
        [] -> false
        entries -> Enum.all?(entries, &match?({:Certificate, _, :not_encrypted}, &1))
      end
    rescue
      _ -> false
    end
  end

  defp valid_ca?(bundle), do: not Map.has_key?(bundle, "ca_pem")

  defp text?(value, limit) do
    is_binary(value) and byte_size(value) in 1..limit and String.valid?(value) and
      not String.contains?(value, [<<0>>, "\r", "\n"])
  end

  defp valid_path?(path) do
    is_binary(path) and text?(path, 4096) and Path.type(path) == :absolute and
      Path.expand(path) == path and path != "/"
  end

  defp remaining(deadline), do: max(deadline - now(), 0)
  defp now, do: System.monotonic_time(:millisecond)
end
