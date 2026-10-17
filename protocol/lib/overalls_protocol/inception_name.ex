defmodule OverallsProtocol.InceptionName do
  @moduledoc "Parent-owned Inception namespaces and fixed nested service selectors."
  alias OverallsProtocol.IngressName
  @type service :: :control_https | :porsche_ssh | :audi_https | :audi_ssh

  # @cc [owner:ghuntley,label:security] inception-namespace-boundary
  # Nested names MUST occupy the dedicated inception branch of the parent zone,
  # include the immutable environment label, and fit the DNS name bound. Exact
  # suffix/label matching MUST reject sibling namespaces and deeper recursion.
  @spec origins(term(), term()) :: {:ok, map()} | {:error, :invalid_inception_name}
  def origins(label, zone) do
    if IngressName.valid_label?(label) and zone?(zone) do
      namespace = label <> ".inception." <> zone
      control = "control." <> namespace
      apps = "apps." <> namespace

      # Reserve room for _acme-challenge, a complete 63-byte workload label
      # and its separator; this also covers the shorter alternate-port prefix.
      if byte_size("_acme-challenge.") + 63 + 1 + byte_size(apps) <= 253 do
        {:ok, %{namespace: namespace, control: control, apps: apps}}
      else
        {:error, :invalid_inception_name}
      end
    else
      {:error, :invalid_inception_name}
    end
  end

  # @cc [owner:ghuntley,label:security] inception-route-fixed-service
  # Public TLS names MUST select only the environment's control or Audi service.
  # A hostname MUST NOT select a port, address, path or arbitrary service; inner
  # workload and alternate-port names remain subject to inner authorization.
  @spec route(term(), term()) :: {:ok, binary(), service()} | :error
  def route(host, zone) when is_binary(host) and byte_size(host) <= 253 do
    if zone?(zone) do
      suffix = String.split(zone, ".")
      parts = String.split(host, ".")
      count = length(parts) - length(suffix)

      if count > 0 and Enum.drop(parts, count) == suffix do
        route_parts(Enum.take(parts, count), zone)
      else
        :error
      end
    else
      :error
    end
  end

  def route(_, _), do: :error

  defp route_parts(["control", label, "inception"], zone),
    do: routed(label, zone, :control_https)

  defp route_parts([workload, "apps", label, "inception"], zone) do
    if match?({:ok, _, _}, IngressName.application_label(workload)),
      do: routed(label, zone, :audi_https),
      else: :error
  end

  defp route_parts(_, _), do: :error

  defp routed(label, zone, service) do
    case origins(label, zone) do
      {:ok, _} -> {:ok, label, service}
      _ -> :error
    end
  end

  # @cc [owner:ghuntley,label:security] inception-ssh-selector
  # SSH routing MUST accept exactly one immutable environment label and one of
  # two fixed service names. Shell syntax, arbitrary destinations and whitespace
  # variants MUST fail; no peer string may create an atom.
  @spec ssh_selector(term()) :: {:ok, binary(), service()} | :error
  def ssh_selector(command) when is_binary(command) and byte_size(command) <= 96 do
    case String.split(command, " ") do
      ["inception", label, "porsche"] -> ssh_label(label, :porsche_ssh)
      ["inception", label, "audi"] -> ssh_label(label, :audi_ssh)
      _ -> :error
    end
  end

  def ssh_selector(_), do: :error

  defp ssh_label(label, service) do
    if IngressName.valid_label?(label), do: {:ok, label, service}, else: :error
  end

  # @cc [owner:ghuntley,label:security] dns-publication-relative-name
  # Publication owners MUST be a stable VM label or one fixed single-layer
  # Inception control/app owner. Wildcards, alternate-port aliases and deeper
  # namespace delegation MUST NOT be supplied as independent publications.
  @spec publication?(term()) :: boolean()
  def publication?(name) when is_binary(name) and byte_size(name) <= 253 do
    case String.split(name, ".") do
      [label] ->
        IngressName.valid_label?(label)

      ["control", environment, "inception"] ->
        IngressName.valid_label?(environment)

      [label, "apps", environment, "inception"] ->
        IngressName.valid_label?(label) and IngressName.valid_label?(environment)

      _ ->
        false
    end
  end

  def publication?(_), do: false

  # @cc [owner:ghuntley,label:security;protocol] inception-wildcard-proof-owner
  # Only the exact apps apex inside one valid environment namespace may carry
  # the child's wildcard DNS-01 proof. It MUST NOT become an address owner.
  @spec wildcard_proof_owner?(term()) :: boolean()
  def wildcard_proof_owner?(name) when is_binary(name) do
    case String.split(name, ".") do
      ["apps", environment, "inception"] -> IngressName.valid_label?(environment)
      _ -> false
    end
  end

  def wildcard_proof_owner?(_), do: false

  @spec destination(service()) :: {:control | :audi, 22 | 443}
  def destination(:control_https), do: {:control, 443}
  def destination(:porsche_ssh), do: {:control, 22}
  def destination(:audi_https), do: {:audi, 443}
  def destination(:audi_ssh), do: {:audi, 22}

  defp zone?(zone) when is_binary(zone) and byte_size(zone) in 1..253 do
    Enum.all?(String.split(zone, "."), fn part ->
      byte_size(part) in 1..63 and
        Regex.match?(~r/\A[a-z0-9](?:[a-z0-9-]*[a-z0-9])?\z/, part)
    end)
  end

  defp zone?(_), do: false
end
