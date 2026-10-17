defmodule Marshall.UncertainAdmissionFixture do
  @moduledoc "Test-only admission caller with a separate post-commit response gate."

  @type request :: %{
          idempotency_key: String.t(),
          architecture: :x86_64,
          image_id: String.t(),
          profile: :standard,
          vcpu: pos_integer(),
          memory_bytes: pos_integer(),
          disk_bytes: pos_integer()
        }

  # @cc [owner:ghuntley,label:verification;recovery] admission-response-gate-after-commit
  # The worker MUST call the real authorized provision action before publishing
  # its committed-ID observation. It MUST withhold the caller result until a
  # distinct release, and retire if its observer dies. This fixture MUST NOT
  # alter transaction, receipt or allocation behavior to simulate the fault.
  @spec start(pid(), reference(), request(), Marshall.Accounts.User.t()) :: pid()
  def start(observer, receipt, params, actor) do
    spawn(fn -> run(observer, receipt, params, actor) end)
  end

  @spec run(pid(), reference(), request(), Marshall.Accounts.User.t()) :: :ok
  defp run(observer, receipt, params, actor) do
    observer_ref = Process.monitor(observer)
    {:ok, vm} = Marshall.Compute.provision(params, actor: actor)
    send(observer, {receipt, :committed, self(), vm.id})

    receive do
      {:release, ^receipt} ->
        send(observer, {receipt, :returned, vm.id})
        :ok

      {:DOWN, ^observer_ref, :process, ^observer, _reason} ->
        :ok
    after
      30_000 -> exit(:admission_reply_release_deadline)
    end
  end
end
