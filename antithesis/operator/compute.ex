# @cc [owner:ghuntley,label:security;verification] fixture-compute-closed-actions
# Requests MUST select only the fixed synthetic actors and operations below.
# Mutations MUST use authorized production Ash domain actions. Internal reads may
# enrich a successful authorized read with its current physical identity, but
# MUST NOT grant authority or create, update, or archive records.
defmodule OverallsAntithesis.Compute do
  @moduledoc "Closed, trusted Compute operations for the isolated Antithesis fixture."

  alias OverallsAntithesis.Fixture
  alias Marshall.{Access, Compute}
  alias Marshall.Compute.{Ledger, Operation, PhysicalOutcome, VirtualMachine}
  alias Marshall.Authorization.SystemActor
  require Ash.Query

  @type request :: %{required(String.t()) => String.t() | integer()}
  @type result :: {:ok, map()} | {:error, String.t()}
  @actors ["admin_a", "admin_b", "target"]
  @profiles %{
    "standard" => :standard,
    "customer" => :customer,
    "oss" => :oss,
    "inception" => :inception
  }
  @kinds %{"start" => :start, "stop" => :stop, "delete" => :delete}
  @roles %{
    "web" => :web,
    "viewer" => :viewer,
    "operator" => :operator,
    "manager" => :manager,
    "revoked" => :revoked
  }
  @base ~w(actor operation request_id version)
  @uuid ~r/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/
  @image ~r/\Asha256:[0-9a-f]{64}\z/

  # @cc [owner:ghuntley,label:recovery;verification] compute-receipt-after-return
  # A success receipt MUST be written only after the production action returns
  # success. If invocation or receipt publication fails, the caller MUST observe
  # uncertainty and reconcile by its stable request key; it MUST NOT infer refusal.
  @spec main([String.t()]) :: :ok | no_return()
  def main([operation, manifest_path, request_path, result_path]) do
    true = System.get_env("MARSHALL_INSTANCE_ID") == "enrollment-operator"
    true = Application.get_env(:marshall, :operator_mode) == true
    true = File.regular?("/run/overalls-oracle/fixture.json")

    manifest = Fixture.read_manifest!(manifest_path)
    request = request_path |> File.read!() |> JSON.decode!()
    :ok = validate(request, operation)
    actor = Fixture.actor!(manifest, request["actor"])

    receipt =
      case perform(operation, request, manifest, actor) do
        {:ok, value} -> envelope(request, operation, "ok", %{value: value})
        {:error, reason} -> envelope(request, operation, "error", %{reason: reason})
      end

    File.write!(result_path, JSON.encode!(receipt))
  end

  def main(_), do: raise(ArgumentError, "invalid compute invocation")

  @spec validate(map(), String.t()) :: :ok | no_return()
  defp validate(
         %{"version" => 1, "request_id" => id, "operation" => op, "actor" => actor} = request,
         op
       )
       when actor in @actors and is_binary(id) do
    true = Regex.match?(@uuid, id)

    fields =
      case op do
        "compute.catalog" ->
          @base

        "compute.list" ->
          @base

        "compute.get" ->
          @base ++ ~w(vm_id)

        "compute.operation" ->
          @base ++ ~w(operation_id vm_id)

        "compute.list_access" ->
          @base ++ ~w(vm_id)

        "compute.lifecycle" ->
          @base ++ ~w(kind request_key vm_id)

        "compute.set_access" ->
          @base ++ ~w(recipient request_key role vm_id)

        "compute.provision" ->
          @base ++ ~w(disk_bytes image_id memory_bytes profile request_key vcpu)

        _ ->
          raise(ArgumentError, "unknown compute operation")
      end

    valid_fields? =
      Enum.sort(Map.keys(request)) == Enum.sort(fields) or
        (op == "compute.provision" and
           Enum.sort(Map.keys(request)) == Enum.sort(fields ++ ["name"]))

    true = valid_fields?

    case op do
      "compute.catalog" ->
        :ok

      "compute.list" ->
        :ok

      "compute.get" ->
        uuid!(request["vm_id"])

      "compute.operation" ->
        uuid!(request["vm_id"])
        uuid!(request["operation_id"])
        :ok

      "compute.list_access" ->
        uuid!(request["vm_id"])

      "compute.lifecycle" ->
        uuid!(request["vm_id"])
        uuid!(request["request_key"])
        true = Map.has_key?(@kinds, request["kind"])
        :ok

      "compute.set_access" ->
        uuid!(request["vm_id"])
        uuid!(request["request_key"])
        true = request["recipient"] in @actors
        true = Map.has_key?(@roles, request["role"])
        :ok

      "compute.provision" ->
        uuid!(request["request_key"])
        true = is_binary(request["image_id"]) and Regex.match?(@image, request["image_id"])
        true = Map.has_key?(@profiles, request["profile"])
        true = bounded_integer?(request["vcpu"], 1, 32)
        true = bounded_integer?(request["memory_bytes"], 536_870_912, 274_877_906_944)

        true =
          bounded_integer?(
            request["disk_bytes"],
            2_147_483_648,
            OverallsProtocol.VMShape.maximum_disk_bytes()
          )

        true =
          OverallsProtocol.VMShape.valid?(
            request["vcpu"],
            request["memory_bytes"],
            request["disk_bytes"]
          )

        true =
          not Map.has_key?(request, "name") or OverallsProtocol.MachineName.valid?(request["name"])

        :ok
    end
  end

  defp validate(_, _), do: raise(ArgumentError, "invalid compute request")

  @spec uuid!(term()) :: :ok | no_return()
  defp uuid!(value) when is_binary(value) do
    if Regex.match?(@uuid, value), do: :ok, else: raise(ArgumentError, "invalid uuid")
  end

  defp uuid!(_), do: raise(ArgumentError, "invalid uuid")

  @spec bounded_integer?(term(), integer(), integer()) :: boolean()
  defp bounded_integer?(value, minimum, maximum),
    do: is_integer(value) and value >= minimum and value <= maximum

  @spec perform(String.t(), request(), map(), Marshall.Accounts.User.t()) :: result()
  defp perform("compute.catalog", _request, _manifest, actor) do
    with {:ok, catalog} <- Compute.catalog(%{}, actor: actor) do
      {:ok,
       %{
         images:
           Enum.map(
             catalog.images,
             &Map.take(&1, [:id, :name, :architecture, :minimum_memory_bytes, :minimum_disk_bytes])
           ),
         available: catalog.available,
         capacity_known: catalog.capacity_known,
         sampled_at: DateTime.to_iso8601(catalog.sampled_at)
       }}
    else
      {:error, error} -> refusal(error)
    end
  end

  defp perform("compute.provision", request, _manifest, actor) do
    # A caller can only select an image the current measured-capacity catalog
    # actually offers, or retry its own existing durable request after archive.
    # Admission still performs its own idempotency and serialized capacity checks.
    with {:ok, catalog} <- Compute.catalog(%{}, actor: actor),
         true <-
           Enum.any?(catalog.images, &(&1.id == request["image_id"])) or
             prior_image?(actor.id, request["request_key"], request["image_id"]),
         {:ok, vm} <- Compute.provision(provision_args(request), actor: actor) do
      [operation] = Ledger.read!(Operation, vm_id: vm.id, kind: :provision)
      {:ok, Map.put(vm_projection(vm), :operation_id, operation.id)}
    else
      false -> {:error, "image_unavailable"}
      {:error, error} -> refusal(error)
    end
  end

  defp perform("compute.lifecycle", request, _manifest, actor) do
    case Compute.lifecycle(
           %{
             vm_id: request["vm_id"],
             kind: @kinds[request["kind"]],
             idempotency_key: request["request_key"]
           },
           actor: actor
         ) do
      {:ok, operation} ->
        {:ok,
         %{
           operation_id: operation.id,
           vm_id: operation.vm_id,
           placement_id: operation.placement_id,
           execution_epoch: operation.execution_epoch,
           kind: Atom.to_string(operation.kind),
           request_key: operation.request_key,
           generation: operation.generation,
           status: Atom.to_string(operation.status)
         }}

      {:error, error} ->
        refusal(error)
    end
  end

  defp perform("compute.get", request, _manifest, actor) do
    case Compute.get_vm(%{vm_id: request["vm_id"]}, actor: actor) do
      {:ok, view} ->
        case Ledger.read!(VirtualMachine, id: view.id) do
          [vm] -> {:ok, vm_projection(vm)}
          [] -> {:error, "state_changed"}
        end

      {:error, error} ->
        refusal(error)
    end
  end

  defp perform("compute.operation", request, _manifest, actor) do
    # A current VM read authorizes the internal operation/outcome projection.
    with {:ok, _view} <- Compute.get_vm(%{vm_id: request["vm_id"]}, actor: actor),
         [operation] <-
           Ledger.read!(Operation, id: request["operation_id"], vm_id: request["vm_id"]) do
      {:ok, operation_projection(operation)}
    else
      [] -> {:error, "operation_unavailable"}
      {:error, error} -> refusal(error)
    end
  end

  defp perform("compute.list", _request, _manifest, actor) do
    case Compute.list_vms(%{limit: 100}, actor: actor) do
      {:ok, page} ->
        {:ok, %{items: Enum.map(page.items, &public_projection/1), next_cursor: page.next_cursor}}

      {:error, error} ->
        refusal(error)
    end
  end

  defp perform("compute.set_access", request, manifest, actor) do
    recipient = manifest[request["recipient"]]
    true = is_map(recipient) and is_binary(recipient["email"])

    case Access.set_access(
           %{
             vm_id: request["vm_id"],
             email: recipient["email"],
             role: @roles[request["role"]],
             idempotency_key: request["request_key"]
           },
           actor: actor
         ) do
      {:ok, change} ->
        {:ok,
         %{
           change_id: change.id,
           vm_id: change.vm_id,
           user_id: change.user_id,
           role: Atom.to_string(change.role),
           request_key: change.request_key,
           grant_id: change.grant_id
         }}

      {:error, error} ->
        refusal(error)
    end
  end

  defp perform("compute.list_access", request, _manifest, actor) do
    case Access.list_grants(%{vm_id: request["vm_id"], limit: 100}, actor: actor) do
      {:ok, grants} ->
        {:ok,
         %{
           owner: grant_projection(grants.owner),
           items: Enum.map(grants.items, &grant_projection/1),
           next_cursor: grants.next_cursor
         }}

      {:error, error} ->
        refusal(error)
    end
  end

  @spec prior_image?(String.t(), String.t(), String.t()) :: boolean()
  defp prior_image?(actor_id, request_key, image_id) do
    Ledger.history!(VirtualMachine, owner_id: actor_id, idempotency_key: request_key)
    |> Enum.any?(&(&1.image_id == image_id))
  end

  @spec provision_args(request()) :: map()
  defp provision_args(request) do
    args = %{
      idempotency_key: request["request_key"],
      architecture: :x86_64,
      image_id: request["image_id"],
      profile: @profiles[request["profile"]],
      vcpu: request["vcpu"],
      memory_bytes: request["memory_bytes"],
      disk_bytes: request["disk_bytes"]
    }

    if Map.has_key?(request, "name"), do: Map.put(args, :name, request["name"]), else: args
  end

  @spec vm_projection(VirtualMachine.t()) :: map()
  defp vm_projection(vm) do
    %{
      vm_id: vm.id,
      owner_id: vm.owner_id,
      name: vm.name,
      current_placement_id: vm.current_placement_id,
      host_id: vm.host_id,
      execution_epoch: vm.execution_epoch,
      generation: vm.generation,
      desired_state: Atom.to_string(vm.desired_state),
      observed_state: Atom.to_string(vm.observed_state),
      image_id: vm.image_id,
      profile: Atom.to_string(vm.profile),
      vcpu: vm.vcpu,
      memory_bytes: vm.memory_bytes,
      disk_bytes: vm.disk_bytes,
      archived: not is_nil(vm.archived_at)
    }
  end

  @spec public_projection(map()) :: map()
  defp public_projection(view),
    do: %{
      vm_id: view.id,
      name: view.name,
      desired_state: Atom.to_string(view.desired_state),
      observed_state: Atom.to_string(view.observed_state),
      generation: view.generation,
      profile: Atom.to_string(view.profile)
    }

  @spec grant_projection(map()) :: map()
  defp grant_projection(grant),
    do: %{
      id: Map.get(grant, :id),
      user_id: grant.user_id,
      role: Atom.to_string(grant.role)
    }

  @spec operation_projection(Operation.t()) :: map()
  defp operation_projection(operation) do
    outcome =
      if operation.completion_outcome_id do
        PhysicalOutcome
        |> Ash.Query.filter(
          id == ^operation.completion_outcome_id and operation_id == ^operation.id
        )
        |> Ash.read!(actor: SystemActor.compute())
        |> List.first()
      end

    %{
      operation_id: operation.id,
      vm_id: operation.vm_id,
      placement_id: operation.placement_id,
      execution_epoch: operation.execution_epoch,
      generation: operation.generation,
      kind: Atom.to_string(operation.kind),
      status: Atom.to_string(operation.status),
      completion_outcome_id: operation.completion_outcome_id,
      accepted_outcome:
        if(outcome,
          do: %{
            id: outcome.id,
            host_id: outcome.host_id,
            sequence: outcome.sequence,
            state: outcome.observation["state"],
            guest_ready: outcome.observation["guest_ready"],
            disk_present: outcome.observation["disk_present"],
            compute_empty: outcome.observation["compute_empty"]
          },
          else: nil
        )
    }
  end

  @spec refusal(term()) :: {:error, String.t()} | no_return()
  defp refusal(%Marshall.Compute.Error{reason: reason}) when is_atom(reason),
    do: {:error, Atom.to_string(reason)}

  defp refusal(%Ash.Error.Forbidden{}), do: {:error, "forbidden"}

  defp refusal(%Ash.Error.Invalid{errors: errors}) do
    case Enum.find_value(errors, fn
           %Marshall.Compute.Error{reason: reason} when is_atom(reason) -> Atom.to_string(reason)
           _ -> nil
         end) do
      nil -> {:error, "invalid_request"}
      reason -> {:error, reason}
    end
  end

  defp refusal(error),
    do: raise("compute action failed without definitive refusal: #{inspect(error.__struct__)}")

  @spec envelope(request(), String.t(), String.t(), map()) :: map()
  defp envelope(request, operation, status, details),
    do:
      Map.merge(
        %{version: 1, request_id: request["request_id"], operation: operation, status: status},
        details
      )
end
