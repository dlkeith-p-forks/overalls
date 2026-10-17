defmodule Audi.SSH.Request do
  @moduledoc "Closed SSH exec grammar and host-bound SSH grant validation."
  alias OverallsProtocol.{InceptionName, IngressConnect, IngressName, SSHKey}
  @type selector :: binary() | {:nested, binary(), :porsche_ssh | :audi_ssh}

  @spec parse(term()) :: {:ok, selector()} | :error
  def parse("connect " <> label) when byte_size(label) <= 63 do
    if IngressName.valid_label?(label), do: {:ok, label}, else: :error
  end

  def parse(command) do
    case InceptionName.ssh_selector(command) do
      {:ok, label, service} -> {:ok, {:nested, label, service}}
      :error -> :error
    end
  end

  # @cc [owner:ghuntley,label:security] audi-nested-ssh-grant
  # Nested selectors MUST match a complete local connector binding and canonical
  # published SSH host key. A namespace grant MUST NOT authorize ordinary VM SSH
  # or a different nested service. Missing fields MUST fail closed.
  @spec grant?(term(), selector(), binary()) :: boolean()
  def grant?(
        %{binding: binding, ticket: _, ttl: ttl, host_key: key},
        {:nested, label, service},
        host
      )
      when is_map(binding) and is_integer(ttl) and ttl in 1..30_000 do
    service in [:porsche_ssh, :audi_ssh] and
      match?(%{service: ^service, port: 22, label: ^label, host_id: ^host}, binding) and
      IngressConnect.valid?(binding) and
      match?({:ok, %{public_key: ^key}}, SSHKey.parse(key))
  end

  def grant?(%{binding: binding, ticket: _, ttl: ttl}, label, host)
      when is_binary(label) and is_map(binding) and is_integer(ttl) and ttl in 1..30_000 do
    match?(%{service: :ssh, port: 22, label: ^label, host_id: ^host}, binding) and
      Enum.all?([:vm_id, :placement_id, :host_id, :session_id], fn field ->
        OverallsProtocol.uuid?(Map.get(binding, field))
      end) and is_integer(binding[:execution_epoch]) and binding.execution_epoch > 0 and
      is_integer(binding[:generation]) and binding.generation > 0
  end

  def grant?(_, _, _), do: false

  @spec authority_binding(map()) :: map()
  def authority_binding(grant), do: Map.take(grant, [:binding, :host_key])
end
