defmodule OverallsProtocol.IngressCatalog do
  @moduledoc "Closed bounded gateway inventory; discovery does not authorize execution."

  # @cc [owner:ghuntley,label:security;protocol] ingress-catalog-identity
  # Catalog replies MUST contain at most 10,000 unique VM identities and labels,
  # exact bounded execution fields and at most five seconds of freshness. Callers
  # MUST bind the configured host and count freshness from request start. Unknown
  # fields, partial entries and duplicate identities MUST reject the entire reply.
  @type entry :: %{
          vm_id: String.t(),
          placement_id: String.t(),
          execution_epoch: pos_integer(),
          generation: pos_integer(),
          label: String.t()
        }
  @type t :: %{
          service_id: String.t(),
          host_id: String.t(),
          service_generation: pos_integer(),
          ttl: pos_integer(),
          entries: [entry()]
        }

  @spec decode(term()) :: {:ok, t()} | {:error, :invalid_message}
  def decode(%{"version" => 1, "catalog" => catalog} = envelope) when map_size(envelope) == 2 do
    with %{
           "service_id" => service,
           "host_id" => host,
           "service_generation" => generation,
           "ttl" => ttl,
           "entries" => entries
         }
         when map_size(catalog) == 5 <- catalog,
         true <-
           OverallsProtocol.uuid?(service) and OverallsProtocol.uuid?(host) and
             positive?(generation),
         true <-
           is_integer(ttl) and ttl in 1..5_000 and is_list(entries) and length(entries) <= 10_000,
         true <- Enum.all?(entries, &entry?/1),
         true <-
           unique?(entries, "vm_id") and unique?(entries, "placement_id") and
             unique?(entries, "label") do
      {:ok,
       %{
         service_id: service,
         host_id: host,
         service_generation: generation,
         ttl: ttl,
         entries:
           Enum.map(entries, fn value ->
             %{
               vm_id: value["vm_id"],
               placement_id: value["placement_id"],
               execution_epoch: value["execution_epoch"],
               generation: value["generation"],
               label: value["label"]
             }
           end)
       }}
    else
      _ -> {:error, :invalid_message}
    end
  end

  def decode(_), do: {:error, :invalid_message}

  defp entry?(
         %{
           "vm_id" => vm,
           "placement_id" => placement,
           "execution_epoch" => epoch,
           "generation" => generation,
           "label" => label
         } = value
       )
       when map_size(value) == 5,
       do:
         OverallsProtocol.uuid?(vm) and OverallsProtocol.uuid?(placement) and positive?(epoch) and
           positive?(generation) and OverallsProtocol.IngressName.valid_label?(label) and
           String.ends_with?(label, vm |> String.downcase() |> String.replace("-", ""))

  defp entry?(_), do: false
  defp positive?(value), do: is_integer(value) and value in 1..9_223_372_036_854_775_807

  defp unique?(values, key),
    do: MapSet.size(MapSet.new(values, &Map.fetch!(&1, key))) == length(values)
end
