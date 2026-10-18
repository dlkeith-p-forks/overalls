defmodule Marshall.GitHub do
  @moduledoc "Per-user GitHub OAuth custody and fenced admission for the github-com integration."
  use Ash.Domain, otp_app: :marshall
  alias Marshall.Accounts.{AccountLifecycle, Login, Security, User}
  alias Marshall.Authorization.SystemActor
  alias Marshall.Compute.{Ledger, VirtualMachine}

  alias Marshall.GitHub.{
    AuditEvent,
    AuthorizationAttempt,
    Connection,
    Exclusion,
    Grant,
    Provider,
    Persistence,
    RefreshAttempt,
    RequestLease,
    RestoreEpoch,
    Worker
  }

  require Marshall.Events

  resources do
    resource(Marshall.GitHub.Connection)
    resource(Marshall.GitHub.AuthorizationAttempt)
    resource(Marshall.GitHub.RefreshAttempt)
    resource(Marshall.GitHub.Exclusion)
    resource(Marshall.GitHub.RequestLease)
    resource(Marshall.GitHub.AuditEvent)
    resource(Marshall.GitHub.RestoreEpoch)
  end

  @lease_ms 2000
  @maximum_request_seconds 300
  @type error ::
          :unauthorized
          | :unavailable
          | :not_configured
          | :invalid_callback
          | :identity_in_use
          | :reconnect_required
  @type status_info :: %{
          phase: atom(),
          github_login: binary() | nil,
          github_id: pos_integer() | nil,
          scopes: [binary()],
          expires_at: DateTime.t() | nil,
          exclusions: [binary()],
          configured: boolean()
        }
  @type authorization :: %{
          token: binary(),
          id: binary(),
          generation: pos_integer(),
          lease_id: binary(),
          ttl: pos_integer()
        }

  @spec configured?() :: boolean()
  def configured? do
    Enum.all?([:github_client_id, :github_client_secret_file, :github_redirect_uri], fn key ->
      value = Application.get_env(:marshall, key)
      is_binary(value) and byte_size(value) > 0
    end)
  end

  @spec begin_authorization(User.t(), binary()) ::
          {:ok, %{url: binary(), attempt_id: binary()}} | {:error, error()}
  def begin_authorization(%User{} = actor, jti) when is_binary(jti) do
    private(fn ->
      if configured?() do
        Ledger.transaction(fn ->
          current!(actor.id, jti)
          connection = connection!(actor.id)

          unless connection.phase in [:disconnected, :reconnect_required],
            do: Ledger.rollback(:reconnect_required)

          cancel_attempt!(connection.authorization_attempt_id)
          state = random()
          verifier = random()

          attempt =
            Ledger.create!(AuthorizationAttempt, :record, %{
              connection_id: connection.id,
              state_digest: digest(state),
              login_digest: digest(jti),
              verifier: verifier,
              generation: connection.generation,
              expires_at: DateTime.add(Ledger.now(), 600, :second)
            })

          Ledger.update!(connection, :authorize, %{authorization_attempt_id: attempt.id})
          %{url: Provider.authorization_url(state, digest(verifier)), attempt_id: attempt.id}
        end)
      else
        {:error, :not_configured}
      end
    end)
  end

  def begin_authorization(_, _), do: {:error, :unauthorized}

  # @cc [owner:ghuntley,label:security;concurrency] github-one-use-oauth
  # Callback MUST consume a live state digest bound to this stored login, active
  # account and connection generation before exchanging a code. A replay, expiry,
  # logout or late result after disconnect MUST NOT establish a connection.
  @spec callback(User.t(), binary(), binary(), binary()) ::
          {:ok, status_info()} | {:error, error()}
  def callback(%User{} = actor, jti, state, code)
      when is_binary(jti) and is_binary(state) and byte_size(state) in 32..128 and
             is_binary(code) and byte_size(code) in 1..4096 do
    private(fn ->
      with true <- configured?(),
           {:ok, {attempt, verifier}} <- claim_callback(actor, jti, state) do
        result = exchange_callback(actor, jti, attempt, code, verifier)
        if match?({:error, _}, result), do: abandon_attempt(attempt.id)
        result
      else
        false ->
          {:error, :invalid_callback}

        {:error, reason} when reason in [:unauthorized, :invalid_callback, :identity_in_use] ->
          {:error, reason}

        _ ->
          {:error, :unavailable}
      end
    end)
  end

  def callback(_, _, _, _), do: {:error, :invalid_callback}

  @spec status(User.t()) :: {:ok, status_info()} | {:error, error()}
  def status(%User{} = actor) do
    private(fn ->
      Ledger.transaction(fn ->
        current!(actor.id, Security.jti(actor))
        status!(actor.id)
      end)
    end)
  end

  def status(_), do: {:error, :unauthorized}

  @spec disconnect(User.t()) :: {:ok, status_info()} | {:error, error()}
  def disconnect(%User{} = actor) do
    private(fn ->
      Ledger.transaction(fn ->
        current!(actor.id, Security.jti(actor))
        retire_locked!(actor.id)
        status!(actor.id)
      end)
    end)
  end

  def disconnect(_), do: {:error, :unauthorized}

  # @cc [owner:ghuntley,label:security;recovery] github-disconnect-fences
  # Disconnect/account retirement MUST invalidate the credential generation and
  # pending browser ceremony in the caller's transaction. Revocation jobs MUST
  # contain IDs only; reconnect MUST wait until grant revocation is acknowledged
  # so delayed cleanup cannot revoke a newly connected grant.
  @spec retire_locked!(binary()) :: :ok
  def retire_locked!(user_id) do
    case find_connection(user_id) do
      nil ->
        :ok

      connection ->
        connection = Ledger.lock!(Connection, connection.id)
        cancel_attempt!(connection.authorization_attempt_id)
        cancel_refresh!(connection.refresh_attempt_id)

        if connection.phase != :revoking do
          connection =
            Ledger.update!(connection, :disconnect, %{
              generation: connection.generation + 1,
              authorization_attempt_id: nil
            })

          enqueue!(connection.id, :revoke)
          audit!(connection, :disconnected)

          Ledger.after_commit(fn ->
            Marshall.Events.emit("github.disconnected",
              connection_id: connection.id,
              user_id: user_id
            )
          end)
        end

        :ok
    end
  end

  @spec set_excluded(User.t(), binary(), boolean()) :: {:ok, status_info()} | {:error, error()}
  def set_excluded(%User{} = actor, vm_id, excluded?)
      when is_binary(vm_id) and is_boolean(excluded?) do
    private(fn ->
      Ledger.transaction(fn ->
        current!(actor.id, Security.jti(actor))
        vm_owned!(actor.id, vm_id)
        # Serialize an exclusion change with request admission/renewal.
        connection = connection!(actor.id)
        rows = Ledger.read!(Exclusion, user_id: actor.id, vm_id: vm_id)

        case {excluded?, rows} do
          {true, []} -> Ledger.create!(Exclusion, :exclude, %{user_id: actor.id, vm_id: vm_id})
          {false, [row]} -> Ledger.archive!(row, :remove)
          _ -> :ok
        end

        audit!(connection, if(excluded?, do: :machine_excluded, else: :machine_included), vm_id)

        Ledger.after_commit(fn ->
          Marshall.Events.emit("github.machine_access_changed", user_id: actor.id, vm_id: vm_id)
        end)

        status!(actor.id)
      end)
    end)
  end

  def set_excluded(_, _, _), do: {:error, :unauthorized}

  # @cc [owner:ghuntley,label:security] github-owner-credential-admission
  # Only the current VM owner's non-excluded connected identity may supply a
  # token. Admission MUST pin a durable connection generation; draining refuses
  # new private requests. Disconnected public traffic MUST receive no token.
  # Removing OAuth configuration MUST refuse existing private renewals and make
  # new requests anonymous without deleting or remotely revoking stored grants.
  # Callers additionally MUST validate authenticated host/current execution fences.
  @spec authorization(binary(), binary()) ::
          {:ok, authorization() | :anonymous} | {:error, error()}
  def authorization(owner_id, vm_id) do
    private(fn ->
      Ledger.transaction(fn ->
        edge_owner!(owner_id, vm_id)

        case if(configured?(),
               do: locked_edge_connection(owner_id, vm_id, :new),
               else: :anonymous
             ) do
          :anonymous ->
            :anonymous

          nil ->
            :anonymous

          %Connection{phase: phase}
          when phase in [:disconnected, :revoking, :reconnect_required] ->
            :anonymous

          %Connection{phase: :connected} = connection ->
            now = Ledger.now()
            unless later?(connection.expires_at, now), do: Ledger.rollback(:unauthorized)

            maximum =
              earliest(
                connection.expires_at,
                DateTime.add(now, @maximum_request_seconds, :second)
              )

            expiry = earliest(maximum, DateTime.add(now, @lease_ms, :millisecond))

            lease =
              Ledger.create!(RequestLease, :record, %{
                connection_id: connection.id,
                vm_id: vm_id,
                generation: connection.generation,
                expires_at: expiry,
                maximum_expires_at: maximum
              })

            credentials = decrypt(connection, :credentials)
            token = credentials && credentials["access_token"]

            unless is_binary(token) and byte_size(token) in 1..4096,
              do: Ledger.rollback(:unauthorized)

            %{
              token: token,
              id: connection.id,
              generation: connection.generation,
              lease_id: lease.id,
              ttl: ttl(expiry, now)
            }

          %Connection{phase: phase} when phase in [:draining, :refreshing] ->
            Ledger.rollback(:unavailable)

          _ ->
            Ledger.rollback(:unauthorized)
        end
      end)
    end)
  end

  # @cc [owner:ghuntley,label:security;recovery] github-renewal-never-substitutes
  # Renewal MUST match owner, VM, connection, lease and generation, recheck the
  # exclusion, and never return credentials. Drain renewals MUST stop at the
  # original bounded deadline; expiry, refresh, disconnect and ownership changes
  # MUST refuse the old request rather than substitute another identity.
  @spec renew(binary(), binary(), binary(), binary(), pos_integer()) ::
          {:ok, %{ttl: pos_integer()}} | {:error, error()}
  def renew(owner_id, vm_id, lease_id, connection_id, generation) do
    private(fn ->
      Ledger.transaction(fn ->
        edge_owner!(owner_id, vm_id)
        unless configured?(), do: Ledger.rollback(:unauthorized)
        connection = locked_edge_connection(owner_id, vm_id) || Ledger.rollback(:unauthorized)

        unless connection.id == connection_id and connection.generation == generation and
                 connection.phase in [:connected, :draining],
               do: Ledger.rollback(:unauthorized)

        lease = Ledger.lock!(RequestLease, lease_id) || Ledger.rollback(:unauthorized)
        now = Ledger.now()

        unless lease.connection_id == connection.id and lease.vm_id == vm_id and
                 lease.generation == generation and later?(lease.expires_at, now),
               do: Ledger.rollback(:unauthorized)

        maximum = earliest(connection.expires_at, lease.maximum_expires_at)

        maximum =
          if connection.phase == :draining,
            do: earliest(maximum, connection.drain_deadline),
            else: maximum

        unless later?(maximum, now), do: Ledger.rollback(:unauthorized)
        expiry = earliest(maximum, DateTime.add(now, @lease_ms, :millisecond))
        Ledger.update!(lease, :renew, %{expires_at: expiry})
        %{ttl: ttl(expiry, now)}
      end)
    end)
  end

  @spec renew_anonymous(binary(), binary()) :: {:ok, %{ttl: pos_integer()}} | {:error, error()}
  def renew_anonymous(owner_id, vm_id) do
    private(fn ->
      Ledger.transaction(fn ->
        edge_owner!(owner_id, vm_id)

        case if(configured?(),
               do: locked_edge_connection(owner_id, vm_id, :new),
               else: :anonymous
             ) do
          :anonymous ->
            %{ttl: @lease_ms}

          nil ->
            %{ttl: @lease_ms}

          %Connection{phase: phase}
          when phase in [:disconnected, :revoking, :reconnect_required] ->
            %{ttl: @lease_ms}

          _ ->
            Ledger.rollback(:unauthorized)
        end
      end)
    end)
  end

  @spec close_lease(binary(), binary(), binary()) :: :ok
  def close_lease(owner_id, vm_id, lease_id) do
    private(fn ->
      Ledger.transaction(fn ->
        connection = locked_connection(owner_id)
        lease = Ledger.lock!(RequestLease, lease_id)

        if connection && lease && lease.connection_id == connection.id && lease.vm_id == vm_id,
          do: Ledger.archive!(lease, :close)

        :ok
      end)
    end)

    :ok
  end

  @doc false
  @spec reconcile() :: :ok | {:error, :unavailable}
  def reconcile do
    private(fn ->
      Ledger.transaction(fn ->
        now = Ledger.now()

        for connection <- Ledger.read!(Connection) do
          cond do
            connection.phase == :revoking ->
              enqueue!(connection.id, :revoke)

            connection.phase in [:draining, :refreshing] ->
              enqueue!(connection.id, :refresh)

            connection.phase == :connected and not later?(connection.refresh_due_at, now) ->
              enqueue!(connection.id, :refresh)

            true ->
              :ok
          end
        end

        purge!(now)
        :ok
      end)
      |> case do
        {:ok, :ok} -> :ok
        _ -> {:error, :unavailable}
      end
    end)
  end

  # @cc [owner:ghuntley,label:security;recovery] github-restored-credentials-disabled
  # Operators MUST quiesce serving before applying a database restore and run
  # this invalidation successfully before any replica serves. Every restored
  # connection MUST change generation, lose encrypted credentials and require
  # browser reconnection; ceremonies, staged pairs and request pins MUST be
  # removed in the same transaction. Provider calls MUST NOT occur here.
  @spec invalidate_restored_credentials!() :: :ok
  def invalidate_restored_credentials! do
    result =
      private(fn ->
        Ledger.transaction(fn ->
          Connection
          |> Ledger.read!()
          |> Enum.sort_by(& &1.id)
          |> Enum.each(fn row ->
            connection = Ledger.lock!(Connection, row.id)

            connection =
              Ledger.update!(connection, :invalidate_restored, %{
                generation: connection.generation + 1,
                credentials: nil,
                refresh_attempt_id: nil,
                authorization_attempt_id: nil,
                drain_deadline: nil
              })

            audit!(connection, :restored_invalidated)
          end)

          for resource <- [RequestLease, AuthorizationAttempt, RefreshAttempt],
              row <- Ledger.read!(resource),
              do: Ledger.archive!(row, :purge)

          :ok
        end)
      end)

    case result do
      {:ok, :ok} -> :ok
      _ -> raise "GitHub restored credential invalidation failed"
    end
  end

  @doc "Cold-release restore hook. Starts only the reviewed non-serving operator application."
  @spec invalidate_restored_credentials_before_serving!() :: :ok
  def invalidate_restored_credentials_before_serving! do
    case restore_marker() do
      :absent ->
        :ok

      {:ok, epoch} ->
        if Process.whereis(Marshall.Supervisor),
          do: raise("GitHub restore invalidation requires a stopped serving application")

        Application.put_env(:marshall, :operator_mode, true)

        endpoint =
          Application.fetch_env!(:marshall, MarshallWeb.Endpoint) |> Keyword.put(:server, false)

        Application.put_env(:marshall, MarshallWeb.Endpoint, endpoint)

        case Application.ensure_all_started(:marshall) do
          {:ok, _} -> apply_restore_epoch!(epoch)
          _ -> raise "GitHub restore operator startup failed"
        end
    end
  end

  @doc false
  @spec apply_restore_epoch!(binary()) :: :ok
  def apply_restore_epoch!(epoch) do
    unless OverallsProtocol.uuid?(epoch), do: raise("Invalid GitHub restore marker")
    epoch = String.downcase(epoch)

    result =
      private(fn ->
        Ledger.transaction(fn ->
          Ecto.Adapters.SQL.query!(
            Marshall.Repo,
            "SELECT pg_advisory_xact_lock(hashtextextended('github-restore-epoch', 0))",
            [],
            log: false
          )

          applied = Ledger.lock!(RestoreEpoch, "github")

          if is_nil(applied) or applied.epoch != epoch do
            :ok = invalidate_restored_credentials!()

            if applied,
              do: Ledger.update!(applied, :apply_epoch, %{epoch: epoch}),
              else: Ledger.create!(RestoreEpoch, :record, %{epoch: epoch})
          end

          :ok
        end)
      end)

    case result do
      {:ok, :ok} -> :ok
      _ -> raise "GitHub restore marker application failed"
    end
  end

  defp restore_marker do
    case System.get_env("MARSHALL_GITHUB_RESTORE_EPOCH_FILE") do
      nil ->
        :absent

      path ->
        unless Path.type(path) == :absolute, do: raise("Invalid GitHub restore marker")

        case File.lstat(path <> ".pending") do
          {:error, :enoent} -> :ok
          _ -> raise "GitHub database restore is incomplete"
        end

        case File.lstat(path) do
          {:error, :enoent} ->
            :absent

          {:ok, %File.Stat{type: :regular}} ->
            with {:ok, bytes} <- File.read(path),
                 true <- byte_size(bytes) in 1..64,
                 epoch = String.trim(bytes),
                 true <- OverallsProtocol.uuid?(epoch) do
              {:ok, String.downcase(epoch)}
            else
              _ -> raise "Invalid GitHub restore marker"
            end

          _ ->
            raise "Invalid GitHub restore marker"
        end
    end
  end

  @doc false
  @spec refresh_connection(binary()) :: :ok | {:snooze, pos_integer()} | {:error, :unavailable}
  def refresh_connection(id) do
    private(fn ->
      case if(configured?(), do: prepare_refresh(id), else: {:error, :unavailable}) do
        {:ok, :done} ->
          :ok

        {:ok, :waiting} ->
          {:snooze, 2}

        {:ok, {:send, attempt, refresh_token}} ->
          requested_at = Ledger.now()

          case provider().refresh(refresh_token) do
            {:ok, grant} -> stage_refresh(id, attempt, grant, requested_at)
            _ -> uncertain_refresh(id, attempt.id)
          end

        {:ok, {:validate, attempt}} ->
          validate_refresh(id, attempt)

        _ ->
          {:error, :unavailable}
      end
    end)
  end

  @doc false
  @spec revoke_connection(binary()) :: :ok | {:error, :unavailable}
  def revoke_connection(id) do
    private(fn ->
      with {:ok, {generation, token}} <-
             Ledger.transaction(fn ->
               case Ledger.lock!(Connection, id) do
                 %Connection{phase: :revoking} = connection ->
                   credentials = decrypt(connection, :credentials)
                   {connection.generation, credentials && credentials["access_token"]}

                 _ ->
                   :done
               end
             end) do
        if is_nil(token) or provider().revoke(token) == :ok do
          case Ledger.transaction(fn ->
                 case Ledger.lock!(Connection, id) do
                   %Connection{phase: :revoking, generation: ^generation} = connection ->
                     clear_connection!(connection)
                     :ok

                   _ ->
                     :ok
                 end
               end) do
            {:ok, :ok} -> :ok
            _ -> {:error, :unavailable}
          end
        else
          {:error, :unavailable}
        end
      else
        {:ok, :done} -> :ok
        _ -> {:error, :unavailable}
      end
    end)
  end

  @doc false
  @spec cleanup_authorization(binary()) :: :ok | {:error, :unavailable}
  def cleanup_authorization(id) do
    private(fn ->
      with {:ok, {token, ciphertext}} <-
             Ledger.transaction(fn ->
               case Ledger.lock!(AuthorizationAttempt, id) do
                 %AuthorizationAttempt{} = attempt ->
                   if attempt.phase in [:failed, :cancelled] or
                        not later?(attempt.expires_at, Ledger.now()) do
                     credentials = decrypt(attempt, :issued_credentials)

                     if credentials,
                       do: {credentials["access_token"], attempt.encrypted_issued_credentials},
                       else: :done
                   else
                     :done
                   end

                 _ ->
                   :done
               end
             end),
           :ok <- provider().revoke_token(token),
           {:ok, :ok} <-
             Ledger.transaction(fn ->
               case Ledger.lock!(AuthorizationAttempt, id) do
                 %AuthorizationAttempt{encrypted_issued_credentials: ^ciphertext} = attempt ->
                   Ledger.update!(attempt, :clear_result, %{issued_credentials: nil})

                 _ ->
                   :ok
               end

               :ok
             end) do
        :ok
      else
        {:ok, :done} -> :ok
        _ -> {:error, :unavailable}
      end
    end)
  end

  @doc false
  @spec cleanup_refresh(binary()) :: :ok | {:error, :unavailable}
  def cleanup_refresh(id) do
    private(fn ->
      with {:ok, {token, ciphertext}} <-
             Ledger.transaction(fn ->
               case Ledger.lock!(RefreshAttempt, id) do
                 %RefreshAttempt{phase: :failed} = attempt ->
                   result = decrypt(attempt, :result)
                   if result, do: {result["access_token"], attempt.encrypted_result}, else: :done

                 _ ->
                   :done
               end
             end),
           :ok <- provider().revoke_token(token),
           {:ok, :ok} <-
             Ledger.transaction(fn ->
               case Ledger.lock!(RefreshAttempt, id) do
                 %RefreshAttempt{phase: :failed, encrypted_result: ^ciphertext} = attempt ->
                   Ledger.update!(attempt, :clear_result, %{result: nil})

                 _ ->
                   :ok
               end

               :ok
             end) do
        :ok
      else
        {:ok, :done} -> :ok
        _ -> {:error, :unavailable}
      end
    end)
  end

  defp exchange_callback(actor, jti, attempt, code, verifier) do
    requested_at = Ledger.now()

    with {:ok, grant} <- provider().exchange(code, verifier),
         {:ok, :ok} <- stage_authorization(attempt.id, grant),
         true <- required_scopes?(grant),
         {:ok, identity} <- provider().identity(grant.access_token) do
      finish_callback(actor, jti, attempt, grant, identity, requested_at)
    else
      false ->
        {:error, :invalid_callback}

      {:error, reason} when reason in [:unauthorized, :invalid_callback, :identity_in_use] ->
        {:error, reason}

      _ ->
        {:error, :unavailable}
    end
  end

  defp stage_authorization(id, grant) do
    Persistence.transaction(fn ->
      attempt = Ledger.lock!(AuthorizationAttempt, id) || Ledger.rollback(:invalid_callback)

      unless attempt.phase in [:exchanging, :failed, :cancelled],
        do: Ledger.rollback(:invalid_callback)

      attempt =
        if is_nil(attempt.encrypted_issued_credentials) do
          Ledger.update!(attempt, :stage_result, %{issued_credentials: Grant.encode(grant)})
        else
          unless decrypt(attempt, :issued_credentials) == Grant.encode(grant),
            do: Ledger.rollback(:invalid_callback)

          attempt
        end

      if attempt.phase != :exchanging, do: enqueue_cleanup!(id)
      :ok
    end)
  end

  defp abandon_attempt(id) do
    Ledger.transaction(fn ->
      if attempt = Ledger.lock!(AuthorizationAttempt, id) do
        if attempt.phase in [:pending, :exchanging],
          do: Ledger.update!(attempt, :fail, %{verifier: nil})

        if attempt.encrypted_issued_credentials, do: enqueue_cleanup!(id)
      end

      :ok
    end)
  end

  defp claim_callback(actor, jti, state) do
    Ledger.transaction(fn ->
      current!(actor.id, jti)
      connection = locked_connection(actor.id) || Ledger.rollback(:invalid_callback)

      attempt =
        connection.authorization_attempt_id &&
          Ledger.lock!(AuthorizationAttempt, connection.authorization_attempt_id)

      unless (attempt && attempt.phase == :pending && attempt.state_digest == digest(state) &&
                attempt.login_digest == digest(jti)) and
               attempt.generation == connection.generation and
               connection.phase in [:disconnected, :reconnect_required] and
               later?(attempt.expires_at, Ledger.now()),
             do: Ledger.rollback(:invalid_callback)

      attempt = Ledger.update!(attempt, :exchange, %{})
      {attempt, decrypt(attempt, :verifier)}
    end)
  end

  defp finish_callback(actor, jti, attempt, grant, identity, requested_at) do
    result =
      Ledger.transaction(fn ->
        current!(actor.id, jti)
        connection = locked_connection(actor.id) || Ledger.rollback(:invalid_callback)
        fresh = Ledger.lock!(AuthorizationAttempt, attempt.id)

        unless fresh && fresh.phase == :exchanging &&
                 connection.authorization_attempt_id == fresh.id &&
                 connection.generation == fresh.generation &&
                 connection.phase in [:disconnected, :reconnect_required] &&
                 later?(fresh.expires_at, Ledger.now()),
               do: Ledger.rollback(:invalid_callback)

        # The advisory identity lock makes uniqueness a closed refusal across replicas;
        # the partial unique index remains the final database invariant.
        Ecto.Adapters.SQL.query!(
          Marshall.Repo,
          "SELECT pg_advisory_xact_lock(hashtextextended($1, 0))",
          ["github-identity:" <> Integer.to_string(identity.id)],
          log: false
        )

        if Enum.any?(
             Ledger.read!(Connection, github_id: identity.id),
             &(&1.id != connection.id and &1.phase != :disconnected)
           ),
           do: Ledger.rollback(:identity_in_use)

        attributes =
          credential_attributes(grant, requested_at)
          |> Map.merge(%{
            github_id: identity.id,
            github_login: identity.login,
            generation: connection.generation + 1,
            authorization_attempt_id: nil
          })

        connection = Ledger.update!(connection, :connect, attributes)
        audit!(connection, :connected)
        fresh = Ledger.update!(fresh, :consume, %{verifier: nil})
        Ledger.update!(fresh, :clear_result, %{issued_credentials: nil})

        enqueue!(
          connection.id,
          :refresh,
          Kernel.max(1, DateTime.diff(connection.refresh_due_at, Ledger.now(), :second))
        )

        Ledger.after_commit(fn ->
          Marshall.Events.emit("github.connected",
            connection_id: connection.id,
            user_id: actor.id
          )
        end)

        status!(actor.id)
      end)

    result
  end

  defp prepare_refresh(id) do
    Ledger.transaction(fn ->
      initial = Ledger.read!(Connection, id: id) |> List.first()
      if is_nil(initial), do: Ledger.rollback(:unauthorized)
      AccountLifecycle.admit!(initial.user_id)
      connection = Ledger.lock!(Connection, id)
      now = Ledger.now()

      case connection.phase do
        :connected ->
          if later?(connection.refresh_due_at, now) do
            :done
          else
            attempt =
              Ledger.create!(RefreshAttempt, :record, %{
                connection_id: id,
                generation: connection.generation
              })

            connection =
              Ledger.update!(connection, :drain, %{
                refresh_attempt_id: attempt.id,
                drain_deadline:
                  earliest(
                    connection.expires_at,
                    DateTime.add(now, @maximum_request_seconds, :second)
                  )
              })

            prepare_drained!(connection, attempt, now)
          end

        :draining ->
          attempt = Ledger.lock!(RefreshAttempt, connection.refresh_attempt_id)
          prepare_drained!(connection, attempt, now)

        :refreshing ->
          attempt = Ledger.lock!(RefreshAttempt, connection.refresh_attempt_id)

          case attempt.phase do
            :staged ->
              {:validate, attempt}

            :submitted ->
              if later?(attempt.submission_expires_at, now) do
                :waiting
              else
                reconnect!(connection, attempt)
                :done
              end

            # An abandoned submitted call may have rotated upstream already.
            _ ->
              reconnect!(connection, attempt)
              :done
          end

        _ ->
          :done
      end
    end)
  end

  defp prepare_drained!(connection, attempt, now) do
    active? =
      Enum.any?(
        Ledger.read!(RequestLease,
          connection_id: connection.id,
          generation: connection.generation
        ),
        &later?(&1.expires_at, now)
      )

    if active? and later?(connection.drain_deadline, now) do
      :waiting
    else
      if not later?(connection.refresh_expires_at, now) do
        reconnect!(connection, attempt)
        :done
      else
        credentials = decrypt(connection, :credentials)
        refresh_token = credentials && credentials["refresh_token"]

        if is_binary(refresh_token) do
          Ledger.update!(connection, :start_refresh, %{generation: connection.generation + 1})

          attempt =
            Ledger.update!(attempt, :submit, %{
              submission_expires_at: DateTime.add(now, 60, :second)
            })

          {:send, attempt, refresh_token}
        else
          reconnect!(connection, attempt)
          :done
        end
      end
    end
  end

  defp stage_refresh(id, attempt, grant, received_at) do
    case Persistence.transaction(fn ->
           connection = Ledger.lock!(Connection, id)
           fresh = Ledger.lock!(RefreshAttempt, attempt.id)

           cond do
             matching_refresh?(connection, fresh) and fresh.phase == :submitted ->
               # Stage the exact pair before another network operation. Recovery can
               # revalidate this pair without ever resending the rotating refresh token.
               Ledger.update!(fresh, :stage, %{
                 result:
                   Map.put(Grant.encode(grant), "received_at", DateTime.to_iso8601(received_at))
               })

             matching_refresh?(connection, fresh) and fresh.phase == :staged ->
               staged = decrypt(fresh, :result)

               unless Map.delete(staged, "received_at") == Grant.encode(grant),
                 do: Ledger.rollback(:invalid_callback)

               fresh

             true ->
               if fresh && fresh.phase in [:submitted, :staged, :failed] do
                 payload =
                   Map.put(Grant.encode(grant), "received_at", DateTime.to_iso8601(received_at))

                 existing = decrypt(fresh, :result)

                 if existing && Map.delete(existing, "received_at") != Grant.encode(grant),
                   do: Ledger.rollback(:invalid_callback)

                 action = if fresh.phase == :failed, do: :retain_result, else: :fail
                 Ledger.update!(fresh, action, %{result: existing || payload})
                 enqueue_refresh_cleanup!(fresh.id)
                 :stale
               else
                 if is_nil(fresh), do: :missing, else: :stale
               end
           end
         end) do
      {:ok, %RefreshAttempt{} = staged} -> validate_refresh(id, staged)
      {:ok, :stale} -> :ok
      {:ok, :missing} -> provider().revoke_token(grant.access_token)
      _ -> {:error, :unavailable}
    end
  end

  defp validate_refresh(id, attempt) do
    payload = decrypt(attempt, :result)

    with {:ok, grant} <- Grant.decode(payload),
         true <- required_scopes?(grant),
         {:ok, identity} <- provider().identity(grant.access_token),
         {:ok, received_at, _} <- DateTime.from_iso8601(payload["received_at"]) do
      case Ledger.transaction(fn ->
             connection = Ledger.lock!(Connection, id)
             fresh = Ledger.lock!(RefreshAttempt, attempt.id)

             if matching_refresh?(connection, fresh) and fresh.phase == :staged do
               if identity.id == connection.github_id and
                    later?(DateTime.add(received_at, grant.expires_in, :second), Ledger.now()) do
                 attributes =
                   credential_attributes(grant, received_at)
                   |> Map.merge(%{refresh_attempt_id: nil, drain_deadline: nil})

                 connection = Ledger.update!(connection, :refresh, attributes)
                 audit!(connection, :refresh_connected)
                 Ledger.update!(fresh, :finish, %{result: nil})

                 enqueue!(
                   id,
                   :refresh,
                   Kernel.max(1, DateTime.diff(connection.refresh_due_at, Ledger.now(), :second))
                 )

                 Ledger.after_commit(fn ->
                   Marshall.Events.emit("github.refresh_finished",
                     connection_id: id,
                     outcome: :connected
                   )
                 end)
               else
                 reconnect!(connection, fresh)
               end
             end

             :ok
           end) do
        {:ok, :ok} -> :ok
        _ -> {:error, :unavailable}
      end
    else
      false -> uncertain_refresh(id, attempt.id)
      {:error, :unauthorized} -> uncertain_refresh(id, attempt.id)
      _ -> {:error, :unavailable}
    end
  end

  defp uncertain_refresh(id, attempt_id) do
    case Ledger.transaction(fn ->
           connection = Ledger.lock!(Connection, id)
           attempt = Ledger.lock!(RefreshAttempt, attempt_id)
           if matching_refresh?(connection, attempt), do: reconnect!(connection, attempt)
           :ok
         end) do
      {:ok, :ok} -> :ok
      _ -> {:error, :unavailable}
    end
  end

  defp reconnect!(connection, attempt) do
    Ledger.update!(connection, :require_reconnect, %{
      credentials: nil,
      refresh_attempt_id: nil,
      drain_deadline: nil
    })

    audit!(connection, :refresh_reconnect_required)

    if attempt && attempt.phase in [:pending, :submitted, :staged] do
      Ledger.update!(attempt, :fail, %{})
      if attempt.encrypted_result, do: enqueue_refresh_cleanup!(attempt.id)
    end

    Ledger.after_commit(fn ->
      Marshall.Events.emit("github.refresh_finished",
        connection_id: connection.id,
        outcome: :reconnect_required
      )
    end)

    :ok
  end

  defp matching_refresh?(%Connection{} = connection, %RefreshAttempt{} = attempt),
    do:
      connection.phase == :refreshing and connection.refresh_attempt_id == attempt.id and
        connection.generation == attempt.generation + 1

  defp matching_refresh?(_, _), do: false

  defp credential_attributes(grant, now) do
    expires = DateTime.add(now, grant.expires_in, :second)

    %{
      credentials: %{"access_token" => grant.access_token, "refresh_token" => grant.refresh_token},
      scopes: grant.scopes,
      expires_at: expires,
      refresh_expires_at: DateTime.add(now, grant.refresh_expires_in, :second),
      refresh_due_at: DateTime.add(now, Kernel.max(1, grant.expires_in - 600), :second)
    }
  end

  defp required_scopes?(%Grant{} = grant),
    do: Provider.sufficient_scopes?(grant.scopes)

  defp current!(user_id, jti) do
    AccountLifecycle.admit!(user_id)
    user = Security.lock_user!(user_id)

    unless user && is_nil(user.deleted_at) && is_binary(jti) &&
             match?({:ok, _}, Login.present(jti, user_id)),
           do: Ledger.rollback(:unauthorized)

    user
  end

  defp edge_owner!(owner_id, vm_id) do
    AccountLifecycle.admit!(owner_id)
    vm_owned!(owner_id, vm_id)
    :ok
  end

  defp locked_edge_connection(owner_id, vm_id, mode \\ :credential) do
    connection = locked_connection(owner_id)

    if Ledger.read!(Exclusion, user_id: owner_id, vm_id: vm_id) != [] do
      if mode == :credential, do: Ledger.rollback(:unauthorized), else: :anonymous
    else
      connection
    end
  end

  defp vm_owned!(owner_id, vm_id) do
    case Ledger.read!(VirtualMachine, id: vm_id, owner_id: owner_id) do
      [%VirtualMachine{desired_state: state}] when state != :deleted -> :ok
      _ -> Ledger.rollback(:unauthorized)
    end
  end

  defp connection!(user_id) do
    case locked_connection(user_id) do
      nil -> Ledger.create!(Connection, :register, %{user_id: user_id})
      connection -> connection
    end
  end

  defp find_connection(user_id), do: Ledger.read!(Connection, user_id: user_id) |> List.first()

  defp locked_connection(user_id) do
    case find_connection(user_id) do
      nil -> nil
      connection -> Ledger.lock!(Connection, connection.id)
    end
  end

  defp status!(user_id) do
    connection = find_connection(user_id)
    phase = if connection, do: connection.phase, else: :disconnected

    attempt =
      connection && connection.authorization_attempt_id &&
        Ledger.lock!(AuthorizationAttempt, connection.authorization_attempt_id)

    phase =
      if attempt && attempt.phase in [:pending, :exchanging] &&
           later?(attempt.expires_at, Ledger.now()), do: :authorizing, else: phase

    %{
      phase: phase,
      github_login: connection && connection.github_login,
      github_id: connection && connection.github_id,
      scopes: if(connection, do: connection.scopes, else: []),
      expires_at: connection && connection.expires_at,
      exclusions: Enum.map(Ledger.read!(Exclusion, user_id: user_id), & &1.vm_id),
      configured: configured?()
    }
  end

  defp clear_connection!(connection) do
    Ledger.update!(connection, :revoked, %{
      credentials: nil,
      github_id: nil,
      github_login: nil,
      scopes: [],
      expires_at: nil,
      refresh_expires_at: nil,
      refresh_due_at: nil,
      refresh_attempt_id: nil,
      drain_deadline: nil
    })
  end

  defp audit!(connection, event, vm_id \\ nil) do
    Ledger.create!(AuditEvent, :record, %{
      connection_id: connection.id,
      user_id: connection.user_id,
      generation: connection.generation,
      event: event,
      vm_id: vm_id
    })
  end

  defp cancel_attempt!(nil), do: :ok

  defp cancel_attempt!(id) do
    case Ledger.lock!(AuthorizationAttempt, id) do
      %AuthorizationAttempt{phase: phase} = attempt when phase in [:pending, :exchanging] ->
        Ledger.update!(attempt, :cancel, %{verifier: nil})

      _ ->
        :ok
    end
  end

  defp cancel_refresh!(nil), do: :ok

  defp cancel_refresh!(id) do
    case Ledger.lock!(RefreshAttempt, id) do
      %RefreshAttempt{phase: phase} = attempt when phase in [:pending, :submitted, :staged] ->
        Ledger.update!(attempt, :fail, %{})
        if attempt.encrypted_result, do: enqueue_refresh_cleanup!(attempt.id)

      _ ->
        :ok
    end
  end

  defp enqueue!(id, operation, seconds \\ 0) do
    generation = Ledger.read!(Connection, id: id) |> List.first() |> Map.fetch!(:generation)

    %{"id" => id, "op" => Atom.to_string(operation), "generation" => generation}
    |> Worker.new(schedule_in: seconds)
    |> Oban.insert!()
  end

  defp enqueue_cleanup!(id) do
    %{"id" => id, "op" => "cleanup"} |> Worker.new() |> Oban.insert!()
  end

  defp enqueue_refresh_cleanup!(id) do
    %{"id" => id, "op" => "cleanup_refresh"} |> Worker.new() |> Oban.insert!()
  end

  defp purge!(now) do
    for lease <- Ledger.read!(RequestLease),
        not later?(lease.expires_at, now),
        do: Ledger.archive!(lease, :purge)

    for attempt <- Ledger.read!(AuthorizationAttempt) do
      cond do
        attempt.encrypted_issued_credentials &&
            (attempt.phase in [:failed, :cancelled] or not later?(attempt.expires_at, now)) ->
          enqueue_cleanup!(attempt.id)

        not later?(attempt.expires_at, now) and is_nil(attempt.encrypted_issued_credentials) ->
          Ledger.archive!(attempt, :purge)

        true ->
          :ok
      end
    end

    cutoff = DateTime.add(now, -86_400, :second)

    for attempt <- Ledger.read!(RefreshAttempt) do
      cond do
        attempt.phase == :failed and attempt.encrypted_result ->
          enqueue_refresh_cleanup!(attempt.id)

        attempt.phase in [:finished, :failed] and not later?(attempt.updated_at, cutoff) ->
          Ledger.archive!(attempt, :purge)

        true ->
          :ok
      end
    end
  end

  defp decrypt(record, field),
    do: record |> Ash.load!(field, actor: SystemActor.compute()) |> Map.fetch!(field)

  defp random, do: :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)
  defp digest(value), do: :crypto.hash(:sha256, value) |> Base.url_encode64(padding: false)
  defp provider, do: Application.get_env(:marshall, :github_provider, Provider)
  defp later?(%DateTime{} = left, %DateTime{} = right), do: DateTime.compare(left, right) == :gt
  defp later?(_, _), do: false

  defp earliest(%DateTime{} = left, %DateTime{} = right),
    do: if(later?(left, right), do: right, else: left)

  defp ttl(expiry, now),
    do: Kernel.min(@lease_ms, Kernel.max(1, DateTime.diff(expiry, now, :millisecond)))

  @doc false
  @spec private((-> result)) :: result | {:error, :unavailable | :unauthorized}
        when result: term()
  def private(fun) do
    original = Logger.metadata()
    Logger.metadata(marshall_authentication: true)

    try do
      case fun.() do
        {:error, :forbidden} -> {:error, :unauthorized}
        result -> result
      end
    rescue
      _ -> {:error, :unavailable}
    catch
      :exit, reason ->
        if Keyword.get(opts, :invalid) == :invalid_callback,
          do: {:error, :invalid_callback},
          else: {:error, :unavailable}
    after
      Logger.reset_metadata(original)
    end
  end
end
