defmodule Lilly.SupervisedStop do
  @moduledoc "Closed, payload-free reason classification for supervised component exits."
  require Lilly.Events

  @type component ::
          :runtime | :ingress | :private | :attribution | :status | :vm_actor
  @type reason_category ::
          :normal
          | :shutdown
          | :connector_unavailable
          | :host_lock_lost
          | :vm_supervision_lost
          | :invalid_status_socket
          | :journal_lock_lost
          | :command_store_failed
          | :journal_write_failed
          | :invalid_executor_result
          | :invalid_execution_journal
          | :vm_actor_unavailable
          | :killed
          | :badarg
          | :badmatch
          | :function_clause
          | :undef
          | :exception
          | :unknown_atom
          | :unknown_tuple
          | :unexpected

  # @cc [owner:ghuntley,label:security;observability] supervised-stop-private-reasons
  # Crash reasons can contain credentials, terminal bytes and process state. Only
  # this closed category may enter the reviewed Events catalog; never inspect a
  # reason or its stack in a diagnostic callback.
  @spec category(term()) :: reason_category()
  def category(:normal), do: :normal
  def category(:shutdown), do: :shutdown
  def category({:shutdown, _}), do: :shutdown
  def category(:connector_unavailable), do: :connector_unavailable
  def category(:host_lock_lost), do: :host_lock_lost
  def category(:vm_supervision_lost), do: :vm_supervision_lost
  def category(:invalid_status_socket), do: :invalid_status_socket
  def category(:journal_lock_lost), do: :journal_lock_lost
  def category(:command_store_failed), do: :command_store_failed
  def category(:journal_write_failed), do: :journal_write_failed
  def category(:invalid_executor_result), do: :invalid_executor_result
  def category(:invalid_execution_journal), do: :invalid_execution_journal
  def category(:vm_actor_unavailable), do: :vm_actor_unavailable
  def category(:killed), do: :killed
  def category({:badarg, _}), do: :badarg
  def category({:badmatch, _}), do: :badmatch
  def category({:function_clause, _}), do: :function_clause
  def category({:undef, _}), do: :undef
  def category({{:badarg, _}, _}), do: :badarg
  def category({{:badmatch, _}, _}), do: :badmatch
  def category({{:function_clause, _}, _}), do: :function_clause
  def category({{:undef, _}, _}), do: :undef
  def category({%_{} = _exception, _stack}), do: :exception
  def category(%_{}), do: :exception
  def category(reason) when is_atom(reason), do: :unknown_atom
  def category(reason) when is_tuple(reason), do: :unknown_tuple
  def category(_), do: :unexpected

  # Stack frames may carry argument values. Keep only the compiled call site;
  # count at most 17 arguments and never format or publish their values or metadata.
  @spec location(term()) :: {atom(), atom(), non_neg_integer()}
  def location({:badarg, stack}) when is_list(stack), do: first_frame(stack)
  def location({{:badarg, stack}, _}) when is_list(stack), do: first_frame(stack)
  def location(_), do: {:unknown, :unknown, 0}

  defp first_frame([{module, function, arity, _} | _])
       when is_atom(module) and is_atom(function) and is_integer(arity) and arity in 0..16,
       do: {module, function, arity}

  defp first_frame([{module, function, arguments, _} | _])
       when is_atom(module) and is_atom(function) and is_list(arguments),
       do: {module, function, arguments |> Enum.take(17) |> length() |> min(16)}

  defp first_frame(_), do: {:unknown, :unknown, 0}

  @spec emit(component(), term()) :: :ok
  def emit(component, reason) do
    case category(reason) do
      category when category in [:normal, :shutdown] ->
        :ok

      category ->
        Lilly.Events.emit("lilly.supervised_component_stopped",
          component: component,
          reason: category
        )
    end
  end

  @spec emit_actor(term(), OverallsProtocol.uuid(), OverallsProtocol.uuid()) :: :ok
  def emit_actor(reason, vm_id, placement_id) do
    case category(reason) do
      category when category in [:normal, :shutdown] ->
        :ok

      category ->
        {source_module, source_function, source_arity} = location(reason)

        Lilly.Events.emit("lilly.vm_actor_exit",
          vm_id: vm_id,
          placement_id: placement_id,
          reason: category,
          source_module: source_module,
          source_function: source_function,
          source_arity: source_arity
        )
    end
  end
end
