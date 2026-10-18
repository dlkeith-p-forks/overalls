defmodule Marshall.Inference.Requests do
  @moduledoc "Serialized inference leases and immutable accounting receipts."
  alias Marshall.Compute.{Ledger, VirtualMachine, Operation}
  alias Marshall.Inference.{Credentials, Request}
  alias Marshall.Authorization.SystemActor
  require Ash.Query
  require Marshall.Events
  @ttl 30_000

  # @cc [owner:ghuntley,label:security;concurrency] inference-persist-before-provider
  # Admission MUST authenticate the dedicated host credential and lock host then
  # VM before checking current execution. Request IDs MUST never authorize a
  # second provider attempt, including after an uncertain first response.
  @spec admit(binary(), term()) :: {:ok, map()} | {:error, term()}
  def admit(token, wire) do
    result =
      with {:ok, input} <- OverallsProtocol.Inference.admission(wire) do
        Ledger.transaction(
          fn ->
            authority = Credentials.authenticate_locked!(token)
            if authority.host_id != input.host_id, do: deny!()
            vm = current!(authority.host, input)
            if Ledger.read!(Request, id: input.id) != [], do: Ledger.rollback(:duplicate_request)
            now = Ledger.now()

            row =
              Ledger.create!(
                Request,
                :record,
                Map.merge(input, %{
                  owner_id: vm.owner_id,
                  generation: vm.generation,
                  credential_id: authority.credential_id,
                  expires_at: DateTime.add(now, @ttl, :millisecond)
                })
              )

            view(row)
          end,
          {:provisioner, input.host_id}
        )
      end

    log_outcome(:admit, result, nil)
  end

  @spec identity(binary()) :: {:ok, map()} | {:error, term()}
  def identity(token) do
    Ledger.transaction(fn ->
      authority = Credentials.authenticate_locked!(token)
      %{host_id: authority.host_id}
    end)
  end

  @spec authorize(binary(), term()) :: {:ok, map()} | {:error, term()}
  def authorize(token, wire) do
    with {:ok, binding} <- OverallsProtocol.PrivateServices.binding(wire) do
      Ledger.transaction(fn ->
        authority = Credentials.authenticate_locked!(token)
        if authority.host_id != binding.host_id, do: deny!()
        _ = current!(authority.host, binding)
        %{authorized: true}
      end)
    end
  end

  # @cc [owner:ghuntley,label:security] guest-update-current-release
  # The desired guest artifact MUST be disclosed only for a current authenticated
  # VM execution binding with an agent-enabled profile. The digest and size MUST
  # describe the host's selected Nix release, never guest-supplied identifiers.
  @spec authorize_update(binary(), term()) :: {:ok, map()} | {:error, term()}
  def authorize_update(token, wire) do
    with {:ok, binding} <- OverallsProtocol.PrivateServices.binding(wire),
         {:ok, :eligible} <-
           Ledger.transaction(fn ->
             authority = Credentials.authenticate_locked!(token)
             if authority.host_id != binding.host_id, do: deny!()
             vm = current!(authority.host, binding)
             unless vm.profile in [:oss, :standard, :inception], do: deny!()
             :eligible
           end),
         "/nix/store/" <> _ = root <- System.get_env("OVERALLS_LYRA_RELEASE"),
         {:ok, bytes} <- File.read(Path.join(root, "manifest.json")),
         true <- byte_size(bytes) <= 16_384,
         {:ok, %{"artifacts" => %{"linux-amd64" => %{"sha256" => digest}}}} <- Jason.decode(bytes),
         true <- is_binary(digest) and Regex.match?(~r/\A[0-9a-f]{64}\z/, digest),
         {:ok, %File.Stat{type: :regular, size: size}} <-
           File.stat(Path.join([root, "bin", "linux-amd64"])),
         true <- size > 0 and size <= 104_857_600 do
      {:ok, %{sha256: digest, bytes: size}}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :unavailable}
    end
  end

  @spec renew(binary(), binary()) :: {:ok, map()} | {:error, term()}
  def renew(token, id) do
    if OverallsProtocol.uuid?(id) do
      Ledger.transaction(fn ->
        authority = Credentials.authenticate_locked!(token)
        candidate = List.first(Ledger.read!(Request, id: id)) || deny!()
        if candidate.host_id != authority.host_id, do: deny!()
        vm = current!(authority.host, candidate)
        row = Ledger.lock!(Request, id) || deny!()
        now = Ledger.now()

        unless row.credential_id == authority.credential_id and is_nil(row.completed_at) and
                 row.generation == vm.generation and DateTime.compare(row.expires_at, now) == :gt,
               do: deny!()

        row
        |> Ledger.update!(:renew, %{expires_at: DateTime.add(now, @ttl, :millisecond)})
        |> view()
      end)
    else
      {:error, :invalid_request}
    end
  end

  # @cc [owner:ghuntley,label:accounting] inference-completion-retained-authority
  # A current host credential may report an earlier admitted request after VM
  # stop or relocation. It MUST match that admission's host; repeated identical
  # completion succeeds, conflicting completion fails, and completion MUST NOT
  # renew execution authority or replace the original owner.
  @spec complete(binary(), binary(), term()) :: {:ok, map()} | {:error, term()}
  def complete(token, id, completion) do
    result =
      with true <- OverallsProtocol.uuid?(id),
           {:ok, completion} <- OverallsProtocol.Inference.completion(completion) do
        Ledger.transaction(
          fn ->
            authority = Credentials.authenticate_locked!(token)
            row = Ledger.lock!(Request, id) || deny!()
            if row.host_id != authority.host_id, do: deny!()

            cond do
              row.completion == completion ->
                %{acknowledged: id}

              not is_nil(row.completion) ->
                Ledger.rollback(:completion_conflict)

              true ->
                Ledger.update!(row, :complete, %{
                  completion: completion,
                  completed_at: Ledger.now()
                })

                :ok = Marshall.Inference.Totals.add!(row, completion)
                %{acknowledged: id}
            end
          end,
          :provisioner
        )
      else
        _ -> {:error, :invalid_request}
      end

    log_outcome(:complete, result, id)
  end

  # @cc [owner:ghuntley,label:observability;security] inference-outcomes-after-commit
  # Admission and completion outcomes MUST be emitted only after the outer
  # transaction returns, with safe identifiers and closed refusal reasons.
  # Lease renewal remains deliberately quiet.
  defp log_outcome(:admit, {:ok, %{request_id: request_id, vm_id: vm_id}} = result, _) do
    Marshall.Events.emit("inference.request_admitted", request_id: request_id, vm_id: vm_id)
    result
  end

  defp log_outcome(:complete, {:ok, %{acknowledged: request_id}} = result, _) do
    Marshall.Events.emit("inference.request_completed", request_id: request_id)
    result
  end

  defp log_outcome(_, {:error, reason} = result, request_id) when is_atom(reason) do
    Marshall.Events.emit("inference.request_refused",
      request_id: if(OverallsProtocol.uuid?(request_id || ""), do: request_id),
      reason: reason
    )

    result
  end

  defp log_outcome(_, result, _), do: result

  # @cc [owner:ghuntley,label:security] inference-retired-owner-fence
  # Retiring an owner MUST deny new admission, identity authorization and renewal
  # even before physical VM cleanup. Retained accounting completion stays allowed.

  # @cc [owner:ghuntley,label:security;recovery] inference-resume-current-receipt
  # Same-boot resume MUST admit inference only after its exact current operation
  # completed; pending restore and stale pre-pause execution MUST remain fenced.
  defp current!(host, binding) do
    vm =
      VirtualMachine
      |> Ash.Query.filter(id == ^binding.vm_id)
      |> Ash.Query.lock("FOR SHARE")
      |> Ash.read_one!(actor: SystemActor.compute()) || deny!()

    now = Ledger.now()

    unless match?(
             %Marshall.Accounts.User{deleted_at: nil},
             Marshall.Accounts.Security.current(vm.owner_id)
           ) and
             OverallsProtocol.ProfilePolicy.allows?(vm.profile, :private_services) and
             host.enabled and host.maintenance_mode != :retired and
             is_binary(host.connection_session_id) and
             Marshall.Compute.HostLiveness.authority?(
               host.connection_session_id,
               host.reported_at,
               now
             ) and
             vm.host_id == host.id and vm.current_placement_id == binding.placement_id and
             vm.execution_epoch == binding.execution_epoch and vm.desired_state == :running and
             vm.observed_state == :running and
             Marshall.Compute.RelocationReadinessState.terminal_allowed?(vm),
           do: deny!()

    started =
      Operation
      |> Ash.Query.filter(
        vm_id == ^vm.id and placement_id == ^vm.current_placement_id and
          execution_epoch == ^vm.execution_epoch and generation == ^vm.generation and
          status == :completed and kind in [:start, :provision, :resume]
      )
      |> Ash.exists?(actor: SystemActor.compute())

    unless started, do: deny!()
    vm
  end

  defp view(row),
    do: %{
      request_id: row.id,
      owner_id: row.owner_id,
      host_id: row.host_id,
      vm_id: row.vm_id,
      placement_id: row.placement_id,
      execution_epoch: row.execution_epoch,
      ttl_ms: @ttl,
      admitted_at: DateTime.to_unix(row.inserted_at, :millisecond)
    }

  defp deny!, do: Ledger.rollback(:unauthorized)
end
