defmodule Susan.Operator do
  @moduledoc """
  Operator commands, run against the live node with `bin/susan rpc`; Susan has
  no network admin surface.

      bin/susan rpc 'Susan.Operator.audit_tail(20)'
      bin/susan rpc 'Susan.Operator.audit_export("/var/lib/susan/exports/audit.jsonl")'
      bin/susan rpc 'Susan.Operator.audit_verify()'
      bin/susan rpc 'Susan.Operator.denylist_key("KEY-UUID")'
      bin/susan rpc 'Susan.Operator.block_install("FINGERPRINT")'
      bin/susan rpc 'Susan.Operator.unblock_install("FINGERPRINT")'

  Every command is itself audited (`admin`, `key_denylisted`,
  `install_blocked`) and prints only audit rows or a fixed status word.
  """
  require Susan.Events
  alias Susan.Audit.Log
  alias Susan.Relay.{InstallIdentity, KeyDenial}

  @spec audit_tail(pos_integer()) :: :ok | {:error, :audit_unavailable}
  def audit_tail(count \\ 50) when is_integer(count) and count in 1..10_000 do
    entries = Log.tail(count)

    with :ok <- admin(:audit_read) do
      entries |> Log.export_lines() |> Enum.each(&IO.puts/1)
    end
  end

  @doc "Writes every entry as JSON lines to a new mode-0600 file at an absolute path."
  @spec audit_export(String.t()) :: :ok | {:error, atom()}
  def audit_export(path) when is_binary(path) do
    if Susan.Credentials.canonical_path?(path) and not File.exists?(path) do
      entries = Log.stream()

      with :ok <- admin(:audit_export),
           {:ok, file} <- File.open(path, [:write, :exclusive, :binary]) do
        try do
          :ok = File.chmod(path, 0o600)

          count =
            Enum.reduce(entries, 0, fn entry, count ->
              :ok = IO.binwrite(file, [Log.export_lines([entry]), "\n"])
              count + 1
            end)

          IO.puts("exported #{count}")
        after
          File.close(file)
        end
      end
    else
      IO.puts("refused")
      {:error, :invalid_path}
    end
  end

  @spec audit_verify() :: :ok | {:error, :audit_unavailable | {:broken_at, non_neg_integer()}}
  def audit_verify do
    with :ok <- admin(:audit_verify) do
      result = Log.verify()
      IO.puts(if result == :ok, do: "intact", else: "broken")
      result
    end
  end

  @spec denylist_key(String.t(), :operator | :abuse | :compromised) :: :ok | {:error, :invalid}
  def denylist_key(key_id, reason \\ :operator)
      when reason in [:operator, :abuse, :compromised] do
    with true <- OverallsProtocol.uuid?(key_id),
         {:ok, _} <-
           Log.transaction(:key_denylisted, fn ->
             with {:ok, _} <- KeyDenial.deny(key_id, reason),
                  {:ok, entry} <-
                    Log.append_in_transaction(:key_denylisted, :ok, %{
                      key_id: key_id,
                      reason: reason
                    }),
                  do: {:ok, entry}
           end) do
      unless Susan.Repo.in_transaction?(),
        do: Susan.Events.emit("susan.operator_action", operation: :denylist)

      IO.puts("denied")
    else
      _ ->
        IO.puts("refused")
        {:error, :invalid}
    end
  end

  @spec block_install(String.t()) :: :ok | {:error, :invalid}
  def block_install(fingerprint) do
    with %InstallIdentity{} = identity <- lookup(fingerprint),
         {:ok, _} <-
           Log.transaction(:install_blocked, fn ->
             with {:ok, _} <- InstallIdentity.block(identity),
                  {:ok, entry} <-
                    Log.append_in_transaction(:install_blocked, :ok, %{
                      install_fingerprint: fingerprint
                    }),
                  do: {:ok, entry}
           end) do
      unless Susan.Repo.in_transaction?(),
        do: Susan.Events.emit("susan.install_transition", to: :blocked)

      unless Susan.Repo.in_transaction?(),
        do: Susan.Events.emit("susan.operator_action", operation: :block)

      IO.puts("blocked")
    else
      _ ->
        IO.puts("refused")
        {:error, :invalid}
    end
  end

  @spec unblock_install(String.t()) :: :ok | {:error, :invalid}
  def unblock_install(fingerprint) do
    with %InstallIdentity{} = identity <- lookup(fingerprint),
         {:ok, _} <-
           Log.transaction(:admin, fn ->
             with {:ok, _} <- InstallIdentity.unblock(identity),
                  {:ok, entry} <-
                    Log.append_in_transaction(:admin, :ok, %{
                      install_fingerprint: fingerprint,
                      reason: :unblock
                    }),
                  do: {:ok, entry}
           end) do
      unless Susan.Repo.in_transaction?(),
        do: Susan.Events.emit("susan.install_transition", to: :trusted)

      unless Susan.Repo.in_transaction?(),
        do: Susan.Events.emit("susan.operator_action", operation: :unblock)

      IO.puts("unblocked")
    else
      _ ->
        IO.puts("refused")
        {:error, :invalid}
    end
  end

  defp lookup(fingerprint) when is_binary(fingerprint) do
    if Regex.match?(~r/\A[0-9a-f]{64}\z/, fingerprint),
      do: InstallIdentity.by_fingerprint!(fingerprint),
      else: nil
  end

  defp lookup(_), do: nil

  defp admin(operation) do
    case Log.append(:admin, :ok, %{reason: operation}) do
      {:ok, _} ->
        unless Susan.Repo.in_transaction?(),
          do: Susan.Events.emit("susan.operator_action", operation: operation)

        :ok

      :error ->
        {:error, :audit_unavailable}
    end
  end
end
