defmodule Lilly do
  @moduledoc """
  Host-side operations for the Lilly provisioner.
  """

  @doc """
  Reads CPU topology and memory inventory from this Linux host.
  """
  # @cc [owner:ghuntley,label:capacity] inventory-errors-remain-observable
  # inventory/0 MUST preserve collection errors from Host.Inventory.read/0;
  # callers must not receive a fabricated zero or default capacity on failure.
  @spec inventory() :: {:ok, Lilly.Host.Inventory.t()} | {:error, term()}
  def inventory, do: Lilly.Host.Inventory.read()
end
