defmodule Lilly.VM.ExecutorAdoptionTest do
  use ExUnit.Case, async: true

  alias Lilly.VM.Executor

  test "temporary adoption contention preserves the previous physical observation" do
    for reason <- [:execution_unavailable, :host_already_owned, :network_unavailable] do
      assert Executor.adoption_failure(reason) == {:retry, reason}
    end
  end

  test "an unconfirmed adoption identity cannot be reported as running" do
    for reason <- [:execution_unconfirmed, :network_identity_conflict, :invalid_vm_specification] do
      assert {:ok, %{state: :unknown, reason: :identity_mismatch, compute_empty: false}} =
               Executor.adoption_failure(reason)
    end
  end
end
