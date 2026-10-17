defmodule OverallsProtocol.CloneControl do
  @moduledoc "Closed bounded clone effect exchange; authenticated hosts still enforce local ownership."
  alias OverallsProtocol.{DiskTransfer, Storage, TransferSSH}
  @kinds ~w(prepare probe connect capture copy adopt revoke discard prune)
  # Closed set of host-side reasons for an unconfirmed effect. A reason names the
  # precondition that could not be established; it never carries native output.
  @unconfirmed_reasons ~w(authority_unconfirmed source_unconfirmed source_authority_unconfirmed
    execution_unavailable storage_busy snapshot_unconfirmed copy_unconfirmed stream_unconfirmed
    lease_unconfirmed receive_unconfirmed key_unconfirmed ssh_unconfirmed permit_unconfirmed
    export_revocation_unconfirmed import_cleanup_unconfirmed mount_unconfirmed disk_unconfirmed
    effect_unconfirmed)
  @type command :: map()

  @spec kinds() :: [String.t()]
  def kinds, do: @kinds

  # @cc [owner:ghuntley,label:observability;protocol] clone-unconfirmed-reason-closed
  # An unconfirmed effect result MUST name exactly one reason from this closed
  # set so both consumers can log and persist it without creating atoms from
  # peer input. A bare unconfirmed result or an unknown reason is invalid.
  @spec unconfirmed_reasons() :: [String.t()]
  def unconfirmed_reasons, do: @unconfirmed_reasons

  # @cc [owner:ghuntley,label:security;protocol] clone-effect-closed-envelope
  # Commands MUST bind one clone, host, endpoint and immutable transfer intent.
  # Paths, executable names, private keys and unknown fields MUST be rejected.
  # Batches MUST remain bounded and peer values MUST never create atoms.
  @spec command(term()) :: {:ok, command()} | {:error, atom()}
  def command(
        %{
          "id" => id,
          "clone_id" => clone,
          "host_id" => host,
          "kind" => kind,
          "endpoint" => endpoint,
          "intent" => wire,
          "descriptor" => descriptor,
          "public_key" => public,
          "source_endpoint" => source,
          "source_generation" => generation,
          "revision" => revision,
          "expires_at" => expires
        } = value
      )
      when map_size(value) == 12 do
    with true <- Enum.all?([id, clone, host], &OverallsProtocol.uuid?/1),
         true <- kind in @kinds and endpoint in ["source", "destination"],
         true <-
           kind == "revoke" or
             endpoint ==
               if(kind in ["probe", "capture", "prune"], do: "source", else: "destination"),
         {:ok, %{purpose: :clone} = intent} <- DiskTransfer.intent(wire),
         true <- intent.relocation_id == clone,
         true <-
           if(endpoint == "source", do: intent.source.host_id, else: intent.destination.host_id) ==
             host,
         true <- positive?(generation) and positive?(revision) and positive?(expires),
         true <- is_nil(public) or TransferSSH.public_key?(public),
         true <- is_nil(source) or match?({:ok, _}, TransferSSH.endpoint(source)),
         true <- is_nil(descriptor) or valid_descriptor?(descriptor, intent) do
      {:ok, value}
    else
      _ -> {:error, :invalid_message}
    end
  end

  def command(_), do: {:error, :invalid_message}

  @spec result(term()) :: {:ok, map()} | {:error, atom()}
  def result(%{"id" => id, "kind" => kind, "result" => result} = value)
      when map_size(value) == 3 do
    if OverallsProtocol.uuid?(id) and valid_result?(kind, result),
      do: {:ok, value},
      else: {:error, :invalid_message}
  end

  def result(_), do: {:error, :invalid_message}

  @spec exchange(term()) :: {:ok, map()} | {:error, atom()}
  def exchange(
        %{"version" => 5, "session_id" => session, "epoch" => epoch, "results" => results} = value
      )
      when map_size(value) == 4 do
    with true <- OverallsProtocol.uuid?(session) and positive?(epoch),
         {:ok, results} <- batch(results, &result/1),
         do: {:ok, %{session_id: session, epoch: epoch, results: results}},
         else: (_ -> {:error, :invalid_message})
  end

  def exchange(_), do: {:error, :invalid_message}

  @spec commands(term()) :: {:ok, [command()]} | {:error, atom()}
  def commands(values), do: batch(values, &command/1)

  defp valid_result?(kind, %{"error" => "unconfirmed", "reason" => reason} = result),
    do: kind in @kinds and map_size(result) == 2 and reason in @unconfirmed_reasons

  defp valid_result?("prepare", %{"public_key" => key} = result),
    do: map_size(result) == 1 and TransferSSH.public_key?(key)

  defp valid_result?("capture", %{"descriptor" => descriptor} = result),
    do:
      map_size(result) == 1 and
        match?({:ok, %{purpose: :clone}}, DiskTransfer.descriptor(descriptor))

  defp valid_result?("copy", %{"dataset_guid" => guid} = result),
    do: map_size(result) == 1 and Storage.guid?(guid)

  defp valid_result?(kind, result) when kind in ~w(probe connect adopt revoke discard prune),
    do: result == %{}

  defp valid_result?(_, _), do: false

  defp valid_descriptor?(wire, intent) do
    case DiskTransfer.descriptor(wire) do
      {:ok, descriptor} -> Map.delete(descriptor, :stream) == intent
      _ -> false
    end
  end

  defp positive?(value), do: is_integer(value) and value in 1..9_223_372_036_854_775_807

  defp batch(values, validate) when is_list(values) and length(values) <= 16 do
    if Enum.all?(values, &match?({:ok, _}, validate.(&1))) and
         Enum.uniq_by(values, & &1["id"]) == values,
       do: {:ok, values},
       else: {:error, :invalid_message}
  end

  defp batch(_, _), do: {:error, :invalid_message}
end
