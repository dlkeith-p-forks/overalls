defmodule OverallsProtocol.IngressName do
  @moduledoc "Stable workload labels and private alternate-port hostname syntax."

  # @cc [owner:ghuntley,label:protocol] ingress-name-immutable-identity
  # A label MUST contain the complete immutable VM UUID. Name truncation MUST NOT
  # create identity collisions. Callers MUST persist the initial label so later
  # VM name changes do not change a published URL.
  @spec label(binary(), binary()) :: binary()
  def label(name, vm_id) do
    unless OverallsProtocol.MachineName.valid?(name) and OverallsProtocol.uuid?(vm_id),
      do: raise(ArgumentError, "invalid workload identity")

    prefix = name |> binary_part(0, min(byte_size(name), 22)) |> String.trim_trailing("-")
    "v-" <> prefix <> "-" <> (vm_id |> String.downcase() |> String.replace("-", ""))
  end

  @spec valid_label?(term()) :: boolean()
  def valid_label?(value) when is_binary(value) and byte_size(value) in 34..63,
    do: Regex.match?(~r/\A[a-z][a-z0-9-]*-[0-9a-f]{32}\z/, value)

  def valid_label?(_), do: false

  # @cc [owner:ghuntley,label:protocol] ingress-flat-alternate-name
  # An alternate application MUST remain one DNS label below the fleet zone.
  # The base label is capped at 57 bytes, leaving room for the six-byte port
  # prefix. The full base label remains recoverable without a lookup.
  @spec alternate_label(binary(), integer()) :: binary()
  def alternate_label(label, port) when port in 3000..9999 do
    unless valid_label?(label) and byte_size(label) <= 57,
      do: raise(ArgumentError, "invalid workload label")

    "p" <> Integer.to_string(port) <> "-" <> label
  end

  @spec alternate_port(binary(), binary()) :: {:ok, integer()} | :error
  def alternate_port(name, label) when is_binary(name) and is_binary(label) do
    case name do
      <<port::binary-size(5), "-", _::binary>> ->
        with {:ok, number} <- alternate_port(port),
             true <-
               valid_label?(label) and byte_size(label) <= 57 and
                 alternate_label(label, number) == name do
          {:ok, number}
        else
          _ -> :error
        end

      _ ->
        :error
    end
  end

  def alternate_port(_, _), do: :error

  @spec application_label(term()) :: {:ok, binary(), 0 | 3000..9999} | :error
  def application_label(value) when is_binary(value) and byte_size(value) <= 63 do
    case value do
      <<port::binary-size(5), "-", label::binary>> ->
        case alternate_port(port) do
          {:ok, number} ->
            if valid_label?(label), do: {:ok, label, number}, else: :error

          :error ->
            if valid_label?(value), do: {:ok, value, 0}, else: :error
        end

      _ ->
        if valid_label?(value), do: {:ok, value, 0}, else: :error
    end
  end

  def application_label(_), do: :error

  @spec alternate_port(term()) :: {:ok, integer()} | :error
  def alternate_port(<<"p", a, b, c, d>>)
      when a in ?3..?9 and b in ?0..?9 and c in ?0..?9 and d in ?0..?9,
      do: {:ok, (a - ?0) * 1000 + (b - ?0) * 100 + (c - ?0) * 10 + d - ?0}

  def alternate_port(_), do: :error
end
