defmodule Lilly.Execution do
  @moduledoc """
  Lock-free execution authority for local consumers (ADR-0140).

  Three single writers publish into one `OverallsProtocol.View`:

    * the Runtime publishes `:runtime` while connected and `{:intent, placement}`
      with the exact durable command right after storing it;
    * each VM actor publishes `{:live, placement}` from its liveness machine
      after a running observation, with the command it observed, its executor
      and a `valid_until` deadline. Flow owners are the command's validated
      `owner_id`, so attribution needs no separate owner lookup.

  Readers (egress attribution, ingress, private services) join these rows here
  and never call the Runtime or an actor. An execution is current only while the
  runtime is connected, the live command is identical to the durable intent and
  the deadline has not passed.
  """
  alias OverallsProtocol.View

  @view __MODULE__.View

  @type command :: OverallsProtocol.Execution.command()
  @type live :: %{
          command: command(),
          executor: {module(), term()},
          actor: pid(),
          valid_until: integer()
        }

  @spec child_spec(term()) :: Supervisor.child_spec()
  def child_spec(_), do: View.child_spec(name: @view)

  @doc false
  @spec view() :: atom()
  def view, do: @view

  ## Writers

  @spec runtime_connected(atom()) :: :ok | {:error, :not_owner}
  def runtime_connected(view \\ @view), do: put(view, :runtime, :connected, [])

  @spec runtime_disconnected(atom()) :: :ok
  def runtime_disconnected(view \\ @view), do: delete(view, :runtime)

  @doc "Publishes the durable command just stored for a placement (Runtime only)."
  @spec intent(atom(), command()) :: :ok | {:error, :not_owner}
  def intent(view \\ @view, command) do
    terms =
      if command.kind in [:provision, :start],
        do: address_terms(command, :intent_address) ++ flow_terms(command, :intent_flow),
        else: []

    put(view, {:intent, command.placement_id}, command, terms)
  end

  @spec forget_intent(atom(), OverallsProtocol.uuid()) :: :ok
  def forget_intent(view \\ @view, placement), do: delete(view, {:intent, placement})

  @typedoc "`:boot` grants roster authority only; `:live` grants execution authority."
  @type row :: :boot | :live

  @doc "Publishes one of the calling actor's rows (VM actor only)."
  @spec publish(atom(), row(), command(), {module(), term()}, integer()) ::
          :ok | {:error, :not_owner}
  def publish(view, row, command, executor, valid_until) when row in [:boot, :live] do
    put(
      view,
      {row, command.placement_id},
      %{command: command, executor: executor, actor: self(), valid_until: valid_until},
      []
    )
  end

  @spec withdraw(atom(), row(), OverallsProtocol.uuid()) :: :ok
  def withdraw(view, row, placement) when row in [:boot, :live],
    do: delete(view, {row, placement})

  ## Readers

  # @cc [owner:ghuntley,label:security] execution-view-exact-current-read
  # current/1 MUST return a placement only while the runtime row is connected,
  # the actor's live command is identical to the durable intent row and the
  # live deadline is in the future. Readers MUST NOT call the Runtime or an
  # actor, and MUST treat every missing, stale or mismatched row as refusal.
  @spec current(atom(), OverallsProtocol.uuid()) :: {:ok, View.version(), live()} | :error
  def current(view \\ @view, placement), do: join(view, :live, placement)

  # @cc [owner:ghuntley,label:security] execution-view-boot-roster-only
  # booted/2 and roster/2 MUST apply the same join as current/1 to the actor's
  # boot row, which proves a confined VMM for the current boot but not guest
  # readiness. They MUST be used only for roster bootstrap, never for general
  # private services, ingress or attribution.
  @spec booted(atom(), OverallsProtocol.uuid()) :: {:ok, View.version(), live()} | :error
  def booted(view \\ @view, placement), do: join(view, :boot, placement)

  @doc "The booted execution holding a unique pre-NAT address (roster bootstrap only)."
  @spec roster(atom(), String.t()) :: {:ok, View.version(), live()} | :error
  def roster(view \\ @view, address) when is_binary(address) do
    case View.lookup(view, {:intent_address, address}) do
      [{{:intent, placement}, _version, _command}] -> booted(view, placement)
      _ -> :error
    end
  end

  defp join(view, row, placement) do
    with {:ok, {_, :connected}} <- View.fetch(view, :runtime),
         {:ok, {_, intent}} <- View.fetch(view, {:intent, placement}),
         {:ok, {version, %{command: ^intent} = proof}} <- View.fetch(view, {row, placement}),
         true <- System.monotonic_time(:millisecond) < proof.valid_until do
      {:ok, version, proof}
    else
      _ -> :error
    end
  end

  # @cc [owner:ghuntley,label:security] execution-view-unique-address
  # by_address/1 MUST resolve only when exactly one durable provision/start
  # intent holds the pre-NAT address and that placement is current. Ambiguous,
  # missing or non-current placements MUST refuse.
  @spec by_address(atom(), String.t()) :: {:ok, View.version(), live()} | :error
  def by_address(view \\ @view, address)

  def by_address(view, address) when is_binary(address) do
    case View.lookup(view, {:intent_address, address}) do
      [{{:intent, placement}, _version, _command}] -> current(view, placement)
      _ -> :error
    end
  end

  def by_address(_view, _address), do: :error

  @doc "The current execution owning a kernel flow label and source address."
  @spec by_flow(atom(), String.t(), :inet.ip4_address()) ::
          {:ok, View.version(), live()} | :error
  def by_flow(view \\ @view, label, source) do
    case View.lookup(view, {:intent_flow, label, source}) do
      [{{:intent, placement}, _version, _command}] -> current(view, placement)
      _ -> :error
    end
  end

  ## Internals

  defp put(view, key, value, terms) do
    case View.put(view, key, value, terms) do
      {:ok, _version} ->
        :ok

      {:error, :not_owner} ->
        # First write, or the view restarted: claim, then write once more.
        with :ok <- View.claim(view, key),
             {:ok, _version} <- View.put(view, key, value, terms),
             do: :ok,
             else: (_ -> {:error, :not_owner})
    end
  end

  defp delete(view, key) do
    _ = View.delete(view, key)
    :ok
  end

  defp address_terms(command, tag) do
    case OverallsProtocol.AddressPool.address(command.profile, command.slot) do
      {:ok, address} -> [{tag, address}]
      _ -> []
    end
  end

  # @cc [owner:ghuntley,label:security] flow-route-exact-incarnation
  # A provision/start intent MUST be indexed under exactly its incarnation's
  # kernel label and profile/slot source address; ambiguous flows MUST fail
  # lookup, and a replaced intent MUST no longer resolve under its old flow.
  @doc false
  @spec flow_key(map()) :: {:ok, {String.t(), :inet.ip4_address()}} | :error
  def flow_key(%{kind: kind, host_id: host, profile: profile, slot: slot} = command)
      when kind in [:provision, :start] do
    with {:ok, label} <- Lilly.Network.FlowLabel.token(host, command),
         {:ok, address} <- OverallsProtocol.AddressPool.address(profile, slot),
         {:ok, source} <- :inet.parse_strict_address(String.to_charlist(address)),
         do: {:ok, {label, source}},
         else: (_ -> :error)
  end

  def flow_key(_), do: :error

  defp flow_terms(command, tag) do
    case flow_key(command) do
      {:ok, {label, source}} -> [{tag, label, source}]
      :error -> []
    end
  end
end
