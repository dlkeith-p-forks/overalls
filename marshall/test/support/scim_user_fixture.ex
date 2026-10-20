defmodule Marshall.ScimUserFixture do
  @moduledoc """
  Real SCIM user lifecycle fixtures: an enabled SCIM configuration with a
  bearer token, HTTP requests through `MarshallWeb.Endpoint`, machines placed
  through the real compute coordinators and physical outcomes ingested through
  `Marshall.Compute.Outcomes`.
  """
  import Phoenix.ConnTest
  import Plug.Conn
  require Ash.Query

  alias Marshall.Accounts.{ScimMachineSuspension, User, UserDeletion}
  alias Marshall.Compute
  alias Marshall.Compute.{Host, Ledger, Operation, Outcomes, VirtualMachine}

  @endpoint MarshallWeb.Endpoint
  @user_schema "urn:ietf:params:scim:schemas:core:2.0:User"
  @patch_schema "urn:ietf:params:scim:api:messages:2.0:PatchOp"

  @type scim :: %{token: String.t(), admin: User.t()}
  @type response :: {non_neg_integer(), map() | nil}

  # @cc [owner:ghuntley,label:verification] scim-fixture-real-configuration
  # SCIM fixtures MUST persist only the bearer digest in the enabled
  # configuration and reach users only through the real endpoint, so the
  # digest authentication and ash_scim dispatch are exercised.
  @spec enable!() :: scim()
  def enable! do
    [bootstrap] = Ledger.read!(Marshall.Accounts.AdminBootstrap)
    unless bootstrap.completed, do: Ledger.update!(bootstrap, :complete, %{})
    admin = Marshall.PasskeyFixture.verified_session(Marshall.PasskeyFixture.user(true))

    {:ok, %{enabled: true, token: token}} =
      Marshall.Scim.Configuration
      |> Ash.ActionInput.for_action(:configure, %{operation: :enable}, actor: admin)
      |> Ash.run_action()

    %{token: token, admin: admin}
  end

  @spec request(scim(), atom(), String.t(), map() | nil) :: response()
  def request(%{token: token}, method, path, body \\ nil) do
    conn =
      build_conn()
      |> put_req_header("authorization", "Bearer " <> token)
      |> put_req_header("content-type", "application/scim+json")
      |> put_req_header("accept", "application/scim+json")

    conn = dispatch(conn, @endpoint, method, "/scim/v2" <> path, body && Jason.encode!(body))

    decoded =
      case conn.resp_body do
        "" -> nil
        body -> Jason.decode!(body)
      end

    {conn.status, decoded}
  end

  @spec create_user(scim(), keyword()) :: response()
  def create_user(scim, opts \\ []) do
    name = Keyword.get_lazy(opts, :name, &unique_name/0)
    email = "#{name}@example.test"

    request(scim, :post, "/Users", %{
      "schemas" => [@user_schema],
      "userName" => email,
      "externalId" => Keyword.get(opts, :external_id, "ext-" <> name),
      "active" => Keyword.get(opts, :active, true),
      "emails" => [%{"value" => email, "primary" => true, "type" => "work"}]
    })
  end

  @spec create_user!(scim(), keyword()) :: User.t()
  def create_user!(scim, opts \\ []) do
    {201, %{"id" => id}} = create_user(scim, opts)
    user!(id)
  end

  @spec set_active(scim(), String.t(), boolean()) :: response()
  def set_active(scim, id, active) do
    request(scim, :patch, "/Users/" <> id, %{
      "schemas" => [@patch_schema],
      "Operations" => [%{"op" => "replace", "path" => "active", "value" => active}]
    })
  end

  @spec delete_user(scim(), String.t()) :: response()
  def delete_user(scim, id), do: request(scim, :delete, "/Users/" <> id)

  @spec get_user(scim(), String.t()) :: response()
  def get_user(scim, id), do: request(scim, :get, "/Users/" <> id)

  @spec user!(String.t()) :: User.t()
  def user!(id), do: Marshall.Accounts.Security.current(id)

  @spec unique_name() :: String.t()
  def unique_name,
    do: "scim-" <> (Ash.UUID.generate() |> String.replace("-", "") |> binary_part(0, 16))

  # @cc [owner:ghuntley,label:verification] scim-fixture-moves-database-time
  # Moving past the deadline MUST rewrite only the persisted deadline to before
  # database time; it MUST NOT bypass the production retirement decision.
  @spec expire!(String.t()) :: :ok
  def expire!(user_id) do
    Ecto.Adapters.SQL.query!(
      Marshall.Repo,
      "UPDATE users SET scim_retirement_deadline = (clock_timestamp() AT TIME ZONE 'utc') - interval '1 second' WHERE id = $1 AND scim_retirement_deadline IS NOT NULL",
      [Ecto.UUID.dump!(user_id)],
      log: false
    )

    :ok
  end

  @spec running_vm!(User.t()) :: VirtualMachine.t()
  def running_vm!(owner) do
    {:ok, vm} = Compute.provision(Marshall.ComputeFixtures.request(%{vcpu: 1}), actor: owner)
    [operation] = Ledger.read!(Operation, vm_id: vm.id)
    {:ok, _} = observe(operation, :running)
    vm!(vm.id)
  end

  @spec vm!(String.t()) :: VirtualMachine.t() | nil
  def vm!(id) do
    VirtualMachine
    |> Ash.Query.for_read(:history, %{}, actor: Marshall.Authorization.SystemActor.compute())
    |> Ash.Query.filter(id == ^id)
    |> Ash.read_one!()
  end

  @spec owner_pause!(User.t(), VirtualMachine.t()) :: :ok
  def owner_pause!(owner, vm) do
    {:ok, operation} =
      Compute.lifecycle(%{vm_id: vm.id, kind: :pause, idempotency_key: Ash.UUID.generate()},
        actor: owner
      )

    {:ok, _} = observe(operation, :paused)
    :ok
  end

  @doc "Reports every unfinished pause, stop or delete operation for these VMs as physically done."
  @spec complete_operations!([String.t()]) :: :ok
  def complete_operations!(vm_ids) do
    for id <- vm_ids,
        operation <- Ledger.read!(Operation, vm_id: id),
        operation.kind in [:pause, :stop, :delete],
        operation.status in [:pending, :acknowledged] do
      state =
        case operation.kind do
          :pause -> :paused
          :stop -> :stopped
          :delete -> :deleted
        end

      {:ok, _} = observe(operation, state)
    end

    :ok
  end

  @spec observe(Operation.t(), atom()) :: {:ok, term()} | {:error, term()}
  def observe(operation, state) do
    [vm] = Ledger.read!(VirtualMachine, id: operation.vm_id)
    sequence = System.unique_integer([:positive, :monotonic])

    outcome = %{
      id: Ash.UUID.generate(),
      vm_id: operation.vm_id,
      placement_id: operation.placement_id,
      execution_epoch: operation.execution_epoch,
      operation_id: operation.id,
      generation: operation.generation,
      sequence: sequence,
      state: state,
      compute_empty: state in [:paused, :stopped, :failed, :deleted],
      disk_present: state != :deleted,
      cleanup_complete: state == :deleted,
      reason: :none
    }

    outcome =
      if state == :paused, do: Map.put(outcome, :checkpoint, checkpoint(vm)), else: outcome

    {:ok, typed} =
      OverallsProtocol.Execution.outcome(OverallsProtocol.Execution.encode_outcome(outcome))

    Ledger.transaction(fn ->
      Ledger.lock!(Host, vm.host_id)
      Outcomes.ingest_locked!(vm.host_id, [typed])
    end)
  end

  @spec checkpoint(VirtualMachine.t()) :: map()
  defp checkpoint(vm),
    do: %{
      id: Ash.UUID.generate(),
      memory_bytes: vm.memory_bytes,
      state_bytes: 4096,
      compatibility: "sha256:" <> String.duplicate("a", 64),
      memory_sha256: "sha256:" <> String.duplicate("b", 64),
      state_sha256: "sha256:" <> String.duplicate("c", 64),
      manifest_sha256: "sha256:" <> String.duplicate("d", 64),
      dataset_guid: "71",
      snapshot_guid: "72"
    }

  @spec suspensions(String.t()) :: [ScimMachineSuspension.t()]
  def suspensions(user_id), do: Ledger.read!(ScimMachineSuspension, user_id: user_id)

  @spec deletion(String.t()) :: UserDeletion.t() | nil
  def deletion(user_id), do: List.first(Ledger.read!(UserDeletion, user_id: user_id))
end
