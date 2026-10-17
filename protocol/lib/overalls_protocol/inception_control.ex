defmodule OverallsProtocol.InceptionControl do
  @moduledoc "Host-session-bound requests for one Inception publication offer."
  alias OverallsProtocol.InceptionExchange
  @fields ~w(session_id epoch vm_id placement_id execution_epoch generation)a

  # @cc [owner:ghuntley,label:security] inception-control-closed-execution
  # A request MUST identify one current host session and exact VM execution.
  # Results MUST contain only an offer UUID and bounded child publication; no
  # namespace, address, absolute expiry or service identity may be selected by
  # the host. A child TTL may only shorten the original offer deadline.
  @spec request(term()) :: {:ok, map()} | {:error, :invalid_message}
  def request(%{"version" => 4, "result" => result} = value) when map_size(value) == 8 do
    if Enum.all?(@fields, &Map.has_key?(value, Atom.to_string(&1))) do
      binding = Map.new(@fields, &{&1, Map.fetch!(value, Atom.to_string(&1))})

      with true <-
             Enum.all?(
               [binding.session_id, binding.vm_id, binding.placement_id],
               &OverallsProtocol.uuid?/1
             ),
           true <-
             Enum.all?([binding.epoch, binding.execution_epoch, binding.generation], &positive?/1),
           {:ok, result} <- result(result) do
        {:ok, Map.put(binding, :result, result)}
      else
        _ -> {:error, :invalid_message}
      end
    else
      {:error, :invalid_message}
    end
  end

  def request(_), do: {:error, :invalid_message}

  @offer_fields ~w(host_id session_id epoch offer_id vm_id placement_id execution_epoch generation environment_generation label zone ttl_ms)a
  @offer_keys ["version", "public", "parent" | Enum.map(@offer_fields, &Atom.to_string/1)]

  # @cc [owner:ghuntley,label:protocol] inception-offer-exact-shape
  # An offer MUST carry exactly the fifteen keys Marshall sends: `version`,
  # the twelve bound offer fields, `public` and `parent`. A missing or extra key
  # fails; `public` and `parent` values may still be null.
  @spec offer(term()) :: {:ok, map()} | {:error, :invalid_message}
  def offer(%{"version" => 4} = value) when map_size(value) == 15 do
    if Enum.all?(@offer_keys, &Map.has_key?(value, &1)) do
      result = Map.new(@offer_fields, &{&1, Map.fetch!(value, Atom.to_string(&1))})

      if Enum.all?(
           [
             result.host_id,
             result.session_id,
             result.offer_id,
             result.vm_id,
             result.placement_id
           ],
           &OverallsProtocol.uuid?/1
         ) and
           Enum.all?(
             [
               result.epoch,
               result.execution_epoch,
               result.generation,
               result.environment_generation
             ],
             &positive?/1
           ) and
           is_integer(result.ttl_ms) and result.ttl_ms in 1..5000 and
           match?({:ok, _}, OverallsProtocol.InceptionName.origins(result.label, result.zone)) do
        with {:ok, settings} <- OverallsProtocol.InceptionPublic.validate(value["public"]),
             {:ok, parent} <- OverallsProtocol.InceptionParent.validate(value["parent"]),
             true <-
               is_nil(parent) or
                 (parent["label"] == result.label and parent["zone"] == result.zone) do
          {:ok, result |> Map.put(:public, settings) |> Map.put(:parent, parent)}
        else
          _ -> {:error, :invalid_message}
        end
      else
        {:error, :invalid_message}
      end
    else
      {:error, :invalid_message}
    end
  end

  def offer(_), do: {:error, :invalid_message}

  defp result(nil), do: {:ok, nil}

  defp result(%{"offer_id" => id, "publication" => publication} = value)
       when map_size(value) == 2 do
    with true <- OverallsProtocol.uuid?(id),
         {:ok, _} <- InceptionExchange.encode(publication),
         do: {:ok, %{offer_id: id, publication: publication}},
         else: (_ -> {:error, :invalid_message})
  end

  defp result(_), do: {:error, :invalid_message}
  defp positive?(value), do: is_integer(value) and value in 1..9_223_372_036_854_775_807
end
