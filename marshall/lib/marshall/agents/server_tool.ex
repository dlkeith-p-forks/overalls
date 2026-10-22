defmodule Marshall.Agents.ServerTool do
  @moduledoc """
  Behaviour for model tools that Marshall executes itself instead of the guest.

  A server tool parses the model's arguments into a typed request once (the same
  parser validates the model response), then executes it with the authority of
  the user who prompted the turn. Results are bounded JSON maps; refusals are
  closed atoms with optional typed detail fields.
  """

  @type context :: %{
          command: Marshall.Agents.Command.t(),
          turn: Marshall.Agents.Turn.t(),
          agent_thread: Marshall.Agents.Thread.t(),
          vm: Marshall.Compute.VirtualMachine.t(),
          user_thread: Marshall.Threads.Thread.t() | nil
        }
  @type refusal :: {:error, atom()} | {:error, atom(), map()}
  @type outcome :: {:ok, map()} | refusal()

  @callback tool() :: atom()
  @callback parse(term()) :: {:ok, struct()} | {:error, atom()}
  @doc "`:pending` leaves the command claimed until a later job run resumes it."
  @callback execute(struct(), context(), Marshall.Accounts.User.t()) :: outcome() | :pending
  @doc "The tool-specific audit kind recorded beside `tool_finished`, if any."
  @callback audit_kind(struct()) :: atom() | nil
  @optional_callbacks audit_kind: 1

  @result_limit 65_536

  @doc "Every typed server tool module, keyed by its command tool atom."
  @spec modules() :: %{atom() => module()}
  def modules, do: %{artifact: Marshall.Artifacts.Tool}

  @doc """
  Every command tool Marshall executes itself: the typed modules plus the
  `thread` and `message_board` tools run by `Marshall.Agents.ThreadToolDispatch`.
  """
  @spec tools() :: [atom()]
  def tools, do: Marshall.Agents.ThreadToolDispatch.tools() ++ Map.keys(modules())

  @doc "Bounds a result to the model wire budget; oversize results become a refusal."
  @spec bound(outcome()) :: {:completed | :failed, map()}
  def bound({:ok, result}) when is_map(result) do
    if byte_size(Jason.encode!(result)) <= @result_limit,
      do: {:completed, result},
      else: {:failed, %{"reason" => "result_too_large"}}
  end

  def bound({:error, reason}) when is_atom(reason), do: bound({:error, reason, %{}})

  def bound({:error, reason, detail}) when is_atom(reason) and is_map(detail),
    do: {:failed, Map.put(stringify(detail), "reason", Atom.to_string(reason))}

  @spec stringify(map()) :: map()
  defp stringify(map), do: Map.new(map, fn {key, value} -> {to_string(key), value} end)
end
