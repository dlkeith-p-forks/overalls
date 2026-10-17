defmodule Marshall.Ingress.Endpoints do
  @moduledoc "VM-serialized endpoint configuration with current Cedar checks."
  use Ash.Resource.Actions.Implementation
  alias Marshall.Access.Authorization
  alias Marshall.Compute.Ledger
  alias Marshall.Ingress.Endpoint

  # @cc [owner:ghuntley,label:security] ingress-endpoint-user-purpose
  # SSH profile identity reads MUST require current VM write permission under the
  # VM lock; metadata reads require read and policy changes require manage.
  # Profiles without web capability MUST reject configuration before endpoint mutation.
  # The SSH profile kind MUST come from the locked VM, never a caller selector.
  # Returning an identity MUST NOT authorize a later SSH connection.
  @impl true
  def run(input, options, %{actor: %Marshall.Accounts.User{} = actor}) do
    Ledger.transaction(fn ->
      action =
        case options[:operation] do
          :configure -> "manage"
          :ssh -> "write"
          :get -> "read"
        end

      vm = Authorization.live_vm!(input.arguments.vm_id, actor, action)

      if options[:operation] == :configure and
           not OverallsProtocol.ProfilePolicy.allows?(vm.profile, :web),
         do: Ledger.rollback(:web_not_allowed)

      endpoint = ensure!(vm)

      endpoint =
        if options[:operation] == :configure,
          do: configure!(endpoint, input.arguments),
          else: endpoint

      view =
        Map.take(endpoint, [:id, :vm_id, :label, :primary_port, :visibility, :policy_revision])

      if options[:operation] == :ssh, do: Map.put(view, :profile, vm.profile), else: view
    end)
    |> case do
      {:error, reason} when is_atom(reason) ->
        {:error, Marshall.Compute.Error.exception(reason: reason)}

      result ->
        result
    end
  end

  def run(_, _, _), do: {:error, Ash.Error.Forbidden.exception([])}

  # @cc [owner:ghuntley,label:concurrency] ingress-endpoint-initialization
  # Callers MUST hold the VM row lock (or its uncommitted insertion) for the whole
  # transaction. Existing labels MUST be retained, including after name changes.
  @spec ensure!(Marshall.Compute.VirtualMachine.t()) :: Endpoint.t()
  def ensure!(vm) do
    endpoint =
      case Ledger.read!(Endpoint, vm_id: vm.id) do
        [endpoint] ->
          endpoint

        [] ->
          Ledger.create!(Endpoint, :record, %{
            vm_id: vm.id,
            label: OverallsProtocol.IngressName.label(vm.name, vm.id)
          })
      end

    Marshall.Ingress.Environments.ensure!(vm, endpoint)
    endpoint
  end

  defp configure!(endpoint, params) do
    if params.primary_port == 4444, do: Ledger.rollback(:reserved_editor_port)

    if endpoint.policy_revision != params.expected_revision,
      do: Ledger.rollback(:revision_conflict)

    if endpoint.primary_port == params.primary_port and endpoint.visibility == params.visibility do
      endpoint
    else
      Ledger.update!(endpoint, :change_policy, %{
        primary_port: params.primary_port,
        visibility: params.visibility,
        policy_revision: endpoint.policy_revision + 1
      })
    end
  end
end
