defmodule Lilly.Ingress.Guardian do
  @moduledoc "Fail-closed local execution watchdog; guest process lifetime is never owned here."

  # @cc [owner:ghuntley,label:security] ingress-watchdog-independent-deadline
  # A guardian MUST require repeated exact runtime/actor authority and die on
  # failure, binding change or stream-owner death. Its independent timer MUST
  # kill it within 1500ms of probe start even if the guardian is suspended.
  # Probes MUST NOT restart a deadline after spending time obtaining authority.
  @spec start({module(), term()}, map()) ::
          {:ok, pid(), tuple()} | {:error, :ingress_unavailable}
  def start(resolver, binding) do
    owner = self()
    tag = make_ref()
    {pid, ref} = spawn_monitor(fn -> run(owner, tag, resolver, binding) end)

    receive do
      {^tag, authority} ->
        Process.demonitor(ref, [:flush])
        {:ok, pid, authority}

      {:DOWN, ^ref, :process, ^pid, _} ->
        {:error, :ingress_unavailable}
    after
      1600 ->
        Process.exit(pid, :kill)
        Process.demonitor(ref, [:flush])
        {:error, :ingress_unavailable}
    end
  end

  defp run(owner, tag, resolver, binding) do
    owner_ref = Process.monitor(owner)
    timer = arm()

    try do
      with {:ok, actor, authority} <- probe(resolver, binding), true <- fresh?(timer) do
        actor_ref = Process.monitor(actor)
        send(owner, {tag, authority})
        loop(owner_ref, actor_ref, resolver, binding, actor, authority, timer)
      end
    rescue
      _ -> :ok
    catch
      _, _ -> :ok
    after
      cancel(timer)
    end
  end

  defp loop(owner_ref, actor_ref, resolver, binding, actor, authority, timer) do
    receive do
      {:DOWN, ref, :process, _, _} when ref == owner_ref or ref == actor_ref ->
        cancel(timer)
        :ok
    after
      250 ->
        # Arm before probing, while the old timer remains in force.
        next_timer = arm()

        case probe(resolver, binding) do
          {:ok, ^actor, ^authority} ->
            if fresh?(timer) and fresh?(next_timer) do
              cancel(timer)
              loop(owner_ref, actor_ref, resolver, binding, actor, authority, next_timer)
            else
              cancel(timer)
              cancel(next_timer)
              :ok
            end

          _ ->
            cancel(timer)
            cancel(next_timer)
            :ok
        end
    end
  end

  defp arm do
    started = System.monotonic_time(:millisecond)
    {:ok, timer} = :timer.exit_after(1500, self(), :kill)
    {timer, started + 1500}
  end

  defp cancel({timer, _}), do: :timer.cancel(timer)
  defp fresh?({_, deadline}), do: System.monotonic_time(:millisecond) < deadline

  # The resolver reads the execution view (Runtime.ingress_authority/2); it
  # never calls the actor, whose pid is returned only to be monitored.
  defp probe({module, context}, binding) do
    case module.ingress_authority(context, binding) do
      {:ok, actor, authority} when is_pid(actor) -> {:ok, actor, authority}
      _ -> {:error, :ingress_unavailable}
    end
  end
end
