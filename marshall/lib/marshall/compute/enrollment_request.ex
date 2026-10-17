defmodule Marshall.Compute.EnrollmentRequest do
  @moduledoc "Versioned operator enrollment input; no secrets, implicit defaults or peer-supplied atoms."
  import Marshall.Compute.CredentialLifetime, only: [valid: 1]
  @maximum 9_223_372_036_854_775_807

  # @cc [owner:ghuntley,label:security] enrollment-request-closed-shape
  # Enrollment input MUST match the exact versioned x86_64 schema, bounded integer
  # overheads/lifetime and 1..64 uniquely named/filesystem-bound pools. Extra
  # fields, duplicate filesystem identities and malformed terms MUST return the
  # fixed invalid_enrollment_request error without creating atoms from input. An
  # optional transfer_endpoint MUST validate as a complete pinned SSH identity;
  # absence disables relocation eligibility and MUST NOT synthesize a key.
  @spec parse(term()) :: {:ok, map()} | {:error, :invalid_enrollment_request}
  def parse(
        %{
          "version" => version,
          "name" => name,
          "architecture" => "x86_64",
          "machine_id" => machine,
          "overhead_cores" => cores,
          "overhead_memory_bytes" => memory,
          "credential_ttl_seconds" => ttl,
          "pools" => pools
        } = input
      )
      when map_size(input) in [8, 9] and version == 3 do
    with true <-
           Map.keys(input) --
             ~w(version name architecture machine_id overhead_cores overhead_memory_bytes credential_ttl_seconds pools transfer_endpoint) ==
             [],
         {:ok, endpoint} <- transfer_endpoint(input),
         true <- name?(name) and OverallsProtocol.Execution.machine_id?(machine),
         true <- integer?(cores, 0, 65_536) and integer?(memory, 0, @maximum),
         true <- valid(ttl),
         true <- is_list(pools) and length(pools) in 1..64,
         {:ok, pools} <- parse_pools(pools, version),
         true <- length(Enum.uniq_by(pools, & &1.name)) == length(pools),
         true <- length(Enum.uniq_by(pools, & &1.filesystem_id)) == length(pools),
         true <- length(Enum.uniq_by(pools, & &1.zpool_guid)) == length(pools) do
      {:ok,
       %{
         host: %{
           name: name,
           architecture: :x86_64,
           machine_id: machine,
           transfer_endpoint: endpoint,
           overhead_cores: cores,
           overhead_memory_bytes: memory
         },
         ttl: ttl,
         pools: pools
       }}
    else
      _ -> {:error, :invalid_enrollment_request}
    end
  end

  def parse(_), do: {:error, :invalid_enrollment_request}

  defp transfer_endpoint(input) do
    case Map.fetch(input, "transfer_endpoint") do
      :error -> {:ok, nil}
      {:ok, value} -> OverallsProtocol.TransferSSH.endpoint(value)
    end
  end

  defp parse_pools(pools, version) do
    Enum.reduce_while(pools, {:ok, []}, fn pool, {:ok, acc} ->
      case parse_pool(pool, version) do
        {:ok, parsed} -> {:cont, {:ok, [parsed | acc]}}
        :error -> {:halt, :error}
      end
    end)
    |> case do
      {:ok, parsed} -> {:ok, Enum.reverse(parsed)}
      :error -> :error
    end
  end

  # @cc [owner:ghuntley,label:capacity] zfs-enrollment-pool-shape
  # V3 enrollment MUST bind ZFS GUIDs. A pool MUST carry exactly `name`, `storage`
  # and `overhead_bytes`; any other key, including the retired
  # `logical_budget_bytes`, MUST be refused rather than ignored (ADR-0159 M31).
  # One host MUST NOT enroll two datasets from one zpool.
  defp parse_pool(%{"name" => name, "storage" => storage, "overhead_bytes" => overhead} = pool, 3)
       when map_size(pool) == 3 do
    with true <- name?(name) and integer?(overhead, 0, @maximum),
         {:ok, identity} <- OverallsProtocol.Storage.identity(storage) do
      {:ok,
       Map.merge(identity, %{
         name: name,
         filesystem_id: OverallsProtocol.Storage.filesystem_id(identity),
         overhead_bytes: overhead
       })}
    else
      _ -> :error
    end
  end

  defp parse_pool(_, _), do: :error

  defp name?(value),
    do: is_binary(value) and Regex.match?(~r/\A[a-zA-Z0-9][a-zA-Z0-9_.-]{0,127}\z/, value)

  defp integer?(n, min, max), do: is_integer(n) and n >= min and n <= max
end
