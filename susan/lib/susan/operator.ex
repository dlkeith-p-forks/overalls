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

  @spec audit_tail(pos_integer()) :: :ok
  def audit_tail(count \\ 50) when is_integer(count) and count in 1..10_000 do
    entries = Log.read(0, 1_000_000)
    entries |> Enum.take(-count) |> Log.export_lines() |> Enum.each(&IO.puts/1)
    admin(:audit_read)
  end

  @doc "Writes every entry as JSON lines to a new mode-0600 file at an absolute path."
  @spec audit_export(String.t()) :: :ok | {:error, :invalid_path}
  def audit_export(path) when is_binary(path) do
    if Susan.Credentials.canonical_path?(path) and not File.exists?(path) do
      lines = Log.read(0, 1_000_000) |> Log.export_lines()
      File.write!(path, Enum.map(lines, &[&1, "\n"]), [:exclusive])
      File.chmod!(path, 0o600)
      IO.puts("exported #{length(lines)}")
      admin(:audit_export)
    else
      IO.puts("refused")
      {:error, :invalid_path}
    end
  end

  @spec audit_verify() :: :ok | {:error, {:broken_at, non_neg_integer()}}
  def audit_verify do
    result = Log.verify()
    IO.puts(if result == :ok, do: "intact", else: "broken")
    _ = admin(:audit_verify)
    result
  end

  @spec denylist_key(String.t(), :operator | :abuse | :compromised) :: :ok | {:error, :invalid}
  def denylist_key(key_id, reason \\ :operator)
      when reason in [:operator, :abuse, :compromised] do
    with true <- OverallsProtocol.uuid?(key_id),
         {:ok, _} <- KeyDenial.deny(key_id, reason),
         {:ok, _} <- Log.append(:key_denylisted, :ok, %{key_id: key_id, reason: reason}) do
      Susan.Events.emit("susan.operator_action", operation: :denylist)
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
         {:ok, _} <- InstallIdentity.block(identity),
         {:ok, _} <- Log.append(:install_blocked, :ok, %{install_fingerprint: fingerprint}) do
      Susan.Events.emit("susan.install_transition", to: :blocked)
      Susan.Events.emit("susan.operator_action", operation: :block)
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
         {:ok, _} <- InstallIdentity.unblock(identity),
         {:ok, _} <-
           Log.append(:admin, :ok, %{install_fingerprint: fingerprint, reason: :unblock}) do
      Susan.Events.emit("susan.install_transition", to: :trusted)
      Susan.Events.emit("susan.operator_action", operation: :unblock)
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
    _ = Log.append(:admin, :ok, %{reason: operation})
    Susan.Events.emit("susan.operator_action", operation: operation)
    :ok
  end
end
