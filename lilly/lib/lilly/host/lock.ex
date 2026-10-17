defmodule Lilly.Host.Lock do
  @moduledoc """
  OS-level leases on Lilly's lock directories, held by lilly-hostd on behalf
  of the calling process (ADR-0176 decision 4).

  hostd keeps the `flock` on each directory's `owner.lock` inode, grants
  waiters in FIFO order and runs the holder's utilities with that descriptor
  inherited. The holder's death releases the lease after hostd killed and
  reaped its commands.
  """
  alias Lilly.Host.{Hostd, Lease, PrivateFiles}

  # @cc [owner:ghuntley,label:recovery;concurrency] bounded-native-lock-acquisition
  # acquire/2 MUST wait at most retry_ms (at most two seconds; zero is one
  # attempt) in hostd's FIFO queue for the directory's owner.lock inode and
  # return :host_already_owned only for contention. Every attempt contends on
  # the same inode. A caller that gives up or dies MUST NOT be left holding a
  # lease granted afterwards.
  @spec acquire(Path.t(), 0..2000) :: {:ok, Lease.t()} | {:error, atom()}
  def acquire(directory, retry_ms) when retry_ms in 0..2000,
    do: open(directory, :exclusive, retry_ms)

  # @cc [owner:ghuntley,label:recovery;concurrency] queued-lock-acquisition
  # await/2 MUST wait at most wait_ms (at most 120 s) in hostd's FIFO queue
  # and otherwise behave as acquire/2. It replaces caller-side polling for
  # pool sections, whose windows exceed two seconds.
  @spec await(Path.t(), 0..120_000) :: {:ok, Lease.t()} | {:error, atom()}
  def await(directory, wait_ms) when wait_ms in 0..120_000,
    do: open(directory, :exclusive, wait_ms)

  # @cc [owner:ghuntley,label:recovery] lock-success-requires-helper-handshake
  # acquire/1 MUST return a lease only after hostd reported the exclusive OS
  # lock granted to this process over an authenticated session. A refusal,
  # timeout or lost session must not establish ownership.
  @spec acquire(Path.t()) :: {:ok, Lease.t()} | {:error, atom()}
  def acquire(directory), do: open(directory, :exclusive, 0)

  # @cc [owner:ghuntley,label:concurrency;recovery] template-reader-lock
  # Shared leases MUST contend on the same stable inode as exclusive builders
  # and retirement. Utility descendants retain the lease after caller death.
  # Callers MUST NOT mutate the protected template under a shared lease.
  @spec shared(Path.t()) :: {:ok, Lease.t()} | {:error, atom()}
  def shared(directory), do: open(directory, :shared, 0)

  defp open(directory, mode, wait_ms) do
    with :ok <- PrivateFiles.directory(directory),
         {:ok, id, session} <- Hostd.acquire(directory, mode, wait_ms) do
      lease = %Lease{id: id, session: session, monitor: Process.monitor(session)}
      Process.put({__MODULE__, :leases}, [lease | Process.get({__MODULE__, :leases}, [])])
      {:ok, lease}
    else
      {:error, :host_already_owned} = error -> error
      _ -> {:error, :host_lock_unavailable}
    end
  end

  # @cc [owner:ghuntley,label:recovery] lock-release-observes-helper-exit
  # release/1 MUST report a confirmed release only after hostd answered that
  # the lease's commands were killed and reaped and its descriptor closed. A
  # lost session or refusal reports uncertainty; the lock inode is never
  # unlinked.
  @spec release(Lease.t()) :: :ok | {:error, :host_lock_release_unconfirmed}
  def release(%Lease{} = lease) do
    result =
      if Process.alive?(lease.session),
        do: Hostd.release(lease.session, lease.id),
        else: {:error, :host_lock_release_unconfirmed}

    Process.demonitor(lease.monitor, [:flush])

    Process.put(
      {__MODULE__, :leases},
      Enum.reject(Process.get({__MODULE__, :leases}, []), &(&1 == lease))
    )

    Lilly.Lifecycle.PublicationDiagnostics.released(lease, result)
    result
  end

  @spec current() :: Lease.t() | nil
  def current, do: Process.get({__MODULE__, :leases}, []) |> List.first()

  @doc "Whether this process still holds the given lease over a live session."
  @spec held?(term()) :: boolean()
  def held?(%Lease{} = lease),
    do: lease in Process.get({__MODULE__, :leases}, []) and Process.alive?(lease.session)

  def held?(_), do: false

  @doc "Whether a monitor message reports the loss of this lease's session."
  @spec lost?(term(), Lease.t() | nil) :: boolean()
  def lost?({:DOWN, ref, :process, _, _}, %Lease{monitor: ref}), do: true
  def lost?(_message, _lease), do: false

  # @cc [owner:ghuntley,label:recovery;concurrency] selected-mutation-owner
  # Selection MUST require a live lease already held by this process.
  # Commands in the callback run under that lease, so hostd keeps its
  # descriptor across utility exec and kills them on caller death. Other held
  # leases stay held; normal nesting order is restored afterwards without
  # resurrecting a released lease.
  @spec with_owner(Lease.t() | nil, (-> result)) :: result | {:error, :host_lock_unavailable}
        when result: term()
  def with_owner(owner, fun) do
    leases = Process.get({__MODULE__, :leases}, [])

    if held?(owner) do
      Process.put({__MODULE__, :leases}, [owner | List.delete(leases, owner)])

      try do
        fun.()
      after
        remaining = Process.get({__MODULE__, :leases}, [])

        Process.put(
          {__MODULE__, :leases},
          (remaining -- leases) ++ Enum.filter(leases, &(&1 in remaining))
        )
      end
    else
      {:error, :host_lock_unavailable}
    end
  end
end
