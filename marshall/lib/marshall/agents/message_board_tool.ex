defmodule Marshall.Agents.MessageBoardTool do
  @moduledoc "Server-owned board operations with execution-derived attribution."
  alias Marshall.Agents.{Command, Root}
  alias Marshall.Compute.{Ledger, VirtualMachine}
  alias Marshall.Threads.Thread

  # @cc [owner:ghuntley,label:security;concurrency] board-tool-derived-attribution
  # Board identity and attribution MUST come from the authenticated turn and
  # persisted execution binding, never model arguments. The worker MUST lock
  # the bound user thread before acquiring VM and command authority.
  @spec target(Command.t()) :: Thread.t() | nil
  def target(command) do
    case Ledger.read!(Thread, agent_root_id: command.root_id) do
      [thread] -> thread
      [] -> nil
    end
  end

  @spec execute(Command.t(), String.t(), Thread.t() | nil) :: {:ok, term()} | {:error, atom()}
  def execute(command, actor_id, target) do
    with [root] <- Ledger.read!(Root, id: command.root_id),
         [vm] <- Ledger.read!(VirtualMachine, id: root.vm_id),
         true <- vm.profile in Marshall.MessageBoards.profiles() do
      dispatch(command.arguments, actor_id, vm, root, target)
    else
      _ -> {:error, :forbidden}
    end
  end

  @spec dispatch(map(), String.t(), VirtualMachine.t(), Root.t(), Thread.t() | nil) ::
          {:ok, term()} | {:error, atom()}
  defp dispatch(%{"operation" => "list"} = args, actor, vm, _root, _thread)
       when map_size(args) == 1 do
    posts =
      Marshall.MessageBoards.list!(actor, vm.profile)
      |> Enum.map(fn post ->
        Map.put(post, :thread_url, if(post.thread_id, do: "/threads/" <> post.thread_id))
      end)

    if byte_size(Jason.encode!(posts)) <= 1_048_576,
      do: {:ok, posts},
      else: {:error, :result_too_large}
  end

  defp dispatch(
         %{"operation" => "post", "body" => body, "idempotency_key" => key} = args,
         actor,
         vm,
         root,
         thread
       )
       when map_size(args) == 3 and is_binary(body) and byte_size(body) in 1..65_536 and
              is_binary(key) and byte_size(key) in 1..128 do
    case Marshall.MessageBoards.post!(actor, vm.profile, key, body,
           vm_id: vm.id,
           root_id: root.id,
           thread_id: thread && thread.id
         ) do
      {:ok, post} -> {:ok, Map.delete(post, :body)}
      error -> error
    end
  end

  defp dispatch(_, _, _, _, _), do: {:error, :invalid_arguments}
end
