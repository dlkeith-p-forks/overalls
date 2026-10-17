defmodule Lilly.Host.LockOrder do
  @moduledoc """
  Lock-order validation for leases, in the manner of the kernel's lockdep
  (ADR-0176 decision 4, rank-ordered leases, first stage).

  Every lease directory belongs to a fixed class. When a process that
  already holds leases acquires another, each (held class, acquired class)
  pair is recorded once per BEAM. Acquiring a class while holding one that
  has previously been acquired *under* it is an inversion: two processes
  taking the pair in opposite orders can deadlock (each then waits out its
  bounded queue wait). Inversions are reported as `lilly.lease_order_inverted`;
  enforcement follows once production reports none.
  """

  require Lilly.Events

  @key {__MODULE__, :edges}

  @type class ::
          :host_owner
          | :control_runtime
          | :vm_journal
          | :placement
          | :launch_intent
          | :pool
          | :template
          | :template_access
          | :network
          | :audit
          | :transfer
          | :template_copy
          | :socket
          | :other

  @doc "The lock class of a lease directory."
  @spec class(Path.t()) :: class()
  def class("/run/lilly"), do: :host_owner

  def class(directory) do
    case {Path.basename(directory), Path.basename(Path.dirname(directory))} do
      {"launch", _} -> :launch_intent
      {"lock", _} -> :placement
      {".lilly-storage", _} -> :pool
      {"network-lock", _} -> :network
      {"audit-lock", _} -> :audit
      {"access-lock", _} -> :template_access
      {_, "templates"} -> :template
      {_, "locks"} -> :template_copy
      _ -> path_class(directory)
    end
  end

  defp path_class(directory) do
    cond do
      String.contains?(directory, "/transfer") -> :transfer
      # Socket custody directories Lilly serves (ingress, private services).
      String.starts_with?(directory, "/run/") -> :socket
      String.contains?(directory, "/control") -> :control_runtime
      String.contains?(directory, "/vms/") -> :vm_journal
      true -> :other
    end
  end

  @doc false
  # Forgets every recorded pair (tests only).
  @spec reset() :: :ok
  def reset do
    :persistent_term.erase(@key)
    :ok
  end

  # @cc [owner:ghuntley,label:concurrency] lease-order-inversion-reported
  # acquired/2 MUST record each (held class, acquired class) pair the first
  # time a process holding `held` leases acquires `directory`, and MUST emit
  # lilly.lease_order_inverted exactly when the reverse pair was recorded
  # earlier in this BEAM. Pairs of the same class are not recorded. It never
  # refuses or delays an acquisition.
  @spec acquired([Path.t()], Path.t()) :: :ok
  def acquired([], _directory), do: :ok

  def acquired(held, directory) do
    acquired = class(directory)
    edges = :persistent_term.get(@key, MapSet.new())

    new =
      for holder <- Enum.uniq(Enum.map(held, &class/1)),
          holder != acquired,
          not MapSet.member?(edges, {holder, acquired}),
          do: {holder, acquired}

    Enum.each(new, fn {holder, acquired} ->
      if MapSet.member?(edges, {acquired, holder}),
        do:
          Lilly.Events.emit("lilly.lease_order_inverted",
            held_class: holder,
            acquired_class: acquired
          )
    end)

    if new != [], do: :persistent_term.put(@key, MapSet.union(edges, MapSet.new(new)))
    :ok
  end
end
