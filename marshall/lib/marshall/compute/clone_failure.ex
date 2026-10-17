defmodule Marshall.Compute.CloneFailure do
  @moduledoc "Closed clone failure vocabulary: durable strings and their diagnostic atoms."

  @kinds [:prepare, :probe, :connect, :capture, :copy, :adopt, :revoke, :discard, :prune]

  # Every closed reason appears here as a literal so the reviewed trace schema
  # carries it; peer strings are matched against this list, never interned.
  @reasons [
    :authority_unconfirmed,
    :source_unconfirmed,
    :source_authority_unconfirmed,
    :execution_unavailable,
    :storage_busy,
    :snapshot_unconfirmed,
    :copy_unconfirmed,
    :stream_unconfirmed,
    :lease_unconfirmed,
    :receive_unconfirmed,
    :key_unconfirmed,
    :ssh_unconfirmed,
    :permit_unconfirmed,
    :export_revocation_unconfirmed,
    :import_cleanup_unconfirmed,
    :mount_unconfirmed,
    :disk_unconfirmed,
    :effect_unconfirmed
  ]

  @admission [
    :placement_changed,
    :vm_busy,
    :workload_not_stable,
    :source_unavailable,
    :transfer_busy,
    :source_cleanup_pending,
    :insufficient_capacity,
    :image_requirements_not_met,
    :forbidden,
    :vm_deleted,
    :name_unavailable
  ]

  @lifecycle [
    :destination_start_failed,
    :source_restart_failed,
    :retry_source_restart,
    :source_stop_failed,
    :retry_source_stop,
    :invalid_clone_command
  ]

  @type effect_kind :: unquote(Enum.reduce(@kinds, &{:|, [], [&1, &2]}))
  @type reason :: unquote(Enum.reduce(@reasons, &{:|, [], [&1, &2]}))
  @type failure ::
          unquote(Enum.reduce(@reasons ++ @admission ++ @lifecycle, &{:|, [], [&1, &2]}))
          | :activation_failed

  @doc "The closed set of host reasons, mirroring the clone control protocol."
  @spec reasons() :: [reason()]
  def reasons, do: @reasons

  @spec effect_kinds() :: [effect_kind()]
  def effect_kinds, do: @kinds

  # @cc [owner:ghuntley,label:observability;security] clone-failure-closed-vocabulary
  # Durable failure strings are either an admission or lifecycle reason or
  # `<effect kind>_<host reason>` with both parts from the closed lists; the
  # parsed atoms are the only values that reach the event catalog. Strings
  # outside the vocabulary collapse to activation_failed and never create atoms.
  @spec unconfirmed(effect_kind(), String.t()) :: {:ok, String.t()} | :error
  def unconfirmed(kind, reason) when kind in @kinds and is_binary(reason) do
    case Enum.find(@reasons, &(Atom.to_string(&1) == reason)) do
      nil -> :error
      atom -> {:ok, "#{kind}_#{atom}"}
    end
  end

  def unconfirmed(_, _), do: :error

  @doc "Parse a durable failure string into its effect kind and host reason."
  @spec parse(String.t() | nil) :: {:ok, effect_kind(), reason()} | :error
  def parse(failure) when is_binary(failure) do
    Enum.find_value(@kinds, :error, fn kind ->
      prefix = Atom.to_string(kind) <> "_"

      if String.starts_with?(failure, prefix) do
        rest = String.replace_prefix(failure, prefix, "")

        case Enum.find(@reasons, &(Atom.to_string(&1) == rest)) do
          nil -> nil
          reason -> {:ok, kind, reason}
        end
      end
    end)
  end

  def parse(_), do: :error

  @doc "Diagnostic reason for a durable failure string; unknown strings never intern atoms."
  @spec reason_atom(String.t() | nil) :: failure()
  def reason_atom(failure) when is_binary(failure) do
    case parse(failure) do
      {:ok, _kind, reason} ->
        reason

      :error ->
        Enum.find(@admission ++ @lifecycle, :activation_failed, &(Atom.to_string(&1) == failure))
    end
  end

  def reason_atom(_), do: :activation_failed

  @doc "The effect kind named by an unconfirmed failure string, when it names one."
  @spec effect_atom(String.t() | nil) :: effect_kind() | nil
  def effect_atom(failure) do
    case parse(failure) do
      {:ok, kind, _} -> kind
      :error -> nil
    end
  end
end
