defmodule NativeDnsHold do
  @moduledoc false

  @marker "/run/audi-dns/native-admission-held"

  # @cc [owner:ghuntley,label:verification;security] dns-native-admission-hold
  # This disposable fixture MUST hold the actual DNS worker before it can answer
  # and MUST mark the hold only after the real producer client has returned the
  # recorder-acknowledged ticket to that worker. It MUST NOT manufacture
  # admissions, outcomes or DNS authority. The marker contains no ticket or data.
  #
  # DNS reads are lock-free (ADR-0139), so suspending the directory no longer
  # holds an answer, and an asynchronous return trace can arrive after the
  # worker has answered. A debug hook inside the producer client instead
  # suspends the calling worker while it is necessarily blocked in admit/2,
  # then writes the marker when the acknowledged ticket reply leaves the client.
  # The client is the suspending process, so the hold lasts until it exits.
  @spec arm() :: :ok
  def arm do
    :ok = :sys.install(Audi.RequestRecorder, {&hold/3, :armed})
  end

  # The hook state is a map: on this OTP a two-tuple returned from a :sys
  # debug function removes the function, as if it had answered :done.
  @spec hold(:armed | %{held: pid()}, term(), term()) :: :armed | %{held: pid()} | :done
  defp hold(:armed, {:in, {:"$gen_call", {worker, _tag}, {:admit, worker, _deadline}}}, _name)
       when is_pid(worker) do
    true = :erlang.suspend_process(worker)
    %{held: worker}
  end

  defp hold(%{held: worker}, {:out, ticket, {worker, _tag}, _state}, _name),
    do: acknowledged(ticket)

  defp hold(%{held: worker}, {:out, ticket, {worker, _tag}}, _name),
    do: acknowledged(ticket)

  defp hold(state, _event, _name), do: state

  # Only a recorder-acknowledged ticket counts; an :unrecorded reply leaves no
  # marker, so the scenario fails instead of holding an unadmitted request.
  @spec acknowledged(term()) :: :done
  defp acknowledged(ticket) when is_reference(ticket) do
    :ok = File.write(@marker, "held", [:exclusive])
    :ok = File.chmod(@marker, 0o600)
    :done
  end

  defp acknowledged(_unrecorded), do: :done
end
