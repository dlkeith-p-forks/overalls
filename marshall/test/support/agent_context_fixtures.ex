defmodule Marshall.AgentContextFixtures do
  @moduledoc "Synthetic guest inventory through the real context and executor coordinators."
  import ExUnit.Assertions
  import Kernel, except: [binding: 1]
  import Kernel, except: [binding: 1]
  alias Marshall.Accounts.{GuestAccounts, User}
  alias Marshall.Agents.{Context, ContextSnapshot, Executor, ExecutorSession, Turn}
  alias Marshall.Compute.{Ledger, VirtualMachine}

  @spec context_fixture(Turn.t(), VirtualMachine.t(), User.t()) :: ContextSnapshot.t()
  def context_fixture(turn, vm, actor) do
    {:ok, account} = Ledger.transaction(fn -> GuestAccounts.ensure!(actor.id) end)
    binding = binding(vm)

    executor =
      case Ledger.read!(Executor, vm_id: vm.id) |> Enum.find(&is_nil(&1.invalidated_at)) do
        %Executor{} = current ->
          assert ExecutorSession.supported?(current, :context_inventory)
          current

        nil ->
          assert {:ok, current} = ExecutorSession.register(binding, nil, ["context-v1"])
          current
      end

    settle_context(turn, account, binding, executor, 0)
  end

  defp settle_context(turn, account, binding, executor, attempts) when attempts < 8 do
    case Context.prepare(turn.id) do
      {:ok, snapshot} ->
        snapshot

      {:pending, %{tool: tool, id: command_id}} ->
        assert {:ok, %{id: ^command_id}} =
                 ExecutorSession.claim(binding, executor.id, executor.fence_epoch)

        assert {:ok, _} =
                 ExecutorSession.transition(
                   binding,
                   executor.id,
                   executor.fence_epoch,
                   command_id,
                   :started
                 )

        result =
          case tool do
            :context_inventory ->
              %{
                "version" => 1,
                "working_directory" => turn.working_directory || "/workspace",
                "creator_home" => "/home/" <> account.username,
                "project_root" => nil,
                "inventory_digest" => String.duplicate("a", 64),
                "entries" => [],
                "next_cursor" => nil,
                "warnings" => []
              }

            :context_read ->
              %{
                "version" => 1,
                "path" => "/workspace/AGENTS.md",
                "digest" => String.duplicate("a", 64),
                "offset" => 0,
                "data_base64" => "",
                "next_offset" => nil,
                "eof" => true
              }

            _ ->
              %{"version" => 1, "status" => "unsupported_tool"}
          end

        assert {:ok, _} =
                 ExecutorSession.transition(
                   binding,
                   executor.id,
                   executor.fence_epoch,
                   command_id,
                   :completed,
                   result
                 )

        settle_context(turn, account, binding, executor, attempts + 1)

      other ->
        flunk("context fixture did not produce an operation: #{inspect(other)}")
    end
  end

  defp settle_context(_turn, _account, _binding, _executor, _),
    do: flunk("context fixture exceeded attempts")

  @spec binding(VirtualMachine.t()) :: %{String.t() => String.t() | pos_integer()}
  def binding(vm) do
    %{
      "host_id" => vm.host_id,
      "vm_id" => vm.id,
      "placement_id" => vm.current_placement_id,
      "execution_epoch" => vm.execution_epoch
    }
  end
end
