defmodule Marshall.Compute.SourceRequestPayload do
  @moduledoc "Persisted closed source request wire values."
  use Ash.Type
  @impl true
  def storage_type(_), do: :map

  # @cc [owner:ghuntley,label:security] source-request-storage-validation
  # Non-nil input, stored and dumped requests MUST pass the shared closed source
  # codec. Nil is only the framework's empty field representation; the resource
  # MUST reject nil persistence. Database JSON is not trusted merely because it
  # was persisted.
  @impl true
  def cast_input(nil, _), do: {:ok, nil}

  def cast_input(value, _) do
    case OverallsProtocol.RelocationSource.command(value) do
      {:ok, command} -> {:ok, OverallsProtocol.RelocationSource.encode_command(command)}
      _ -> :error
    end
  end

  @impl true
  def cast_stored(value, constraints), do: cast_input(value, constraints)
  @impl true
  def dump_to_native(value, constraints), do: cast_input(value, constraints)
end
