defmodule Marshall.Scim.LifecyclePropertyTest do
  @moduledoc """
  Generated SCIM event histories against the real endpoint, Oban worker,
  compute coordinator and PostgreSQL state.
  """
  use Marshall.DataCase, async: false
  use Oban.Testing, repo: Marshall.Repo
  import Hegel
  import Hegel.Gen
  import Marshall.ScimUserFixture

  alias Marshall.Accounts.{AccountLifecycle, ScimRetirement, User, UserDeletion}
  alias Marshall.Compute.{Ledger, Operation}
  alias Marshall.Scim.RetirementWorker

  @typep event :: :deactivate | :reactivate | :delete | :expire | :run_worker | :complete | :get
  @typep history :: %{finalized: boolean(), deleting: boolean()}

  @events [:deactivate, :reactivate, :delete, :expire, :run_worker, :complete, :get]

  # @cc [owner:ghuntley,label:verification;recovery] scim-lifecycle-generated-invariants
  # Generated histories MUST drive only production surfaces (endpoint, worker,
  # outcome ingestion) and check after every step: no machine is deleted while
  # the identity is live or inside grace, a finalized identity owns no machine
  # and is ghosted, and a finalized identity never becomes active again.
  @tag :hegel
  @tag :hegel_case_sandbox
  test "SCIM event histories never delete early and never resurrect" do
    Hegel.check(
      fn ->
        Marshall.DataCase.isolate_property_case()
        Marshall.ComputeFixtures.host_fixture()
        scim = enable!()
        user = create_user!(scim)
        vm = running_vm!(user)
        events = draw("events", list_of(member_of(@events), min_length: 1, max_length: 14))

        history =
          Enum.reduce(events, %{finalized: false, deleting: false}, fn event, history ->
            before = user!(user.id)
            status = step(event, scim, user.id, vm.id)
            check_response!(event, status, before)
            check_invariants!(user.id, vm.id, history)
          end)

        # Deactivating, expiring and driving the remaining work always
        # converges on a finalized identity.
        assert {200, _} = set_active(scim, user.id, false) |> accept_refusal()
        expire!(user.id)

        for _ <- 1..3 do
          run_worker!(user.id)
          complete_operations!([vm.id])
        end

        run_worker!(user.id)
        check_invariants!(user.id, vm.id, history)
        assert %User{deleted_at: %DateTime{}, active: false} = user!(user.id)
        assert %UserDeletion{state: :completed} = deletion(user.id)
      end,
      test_cases: 40
    )
  end

  @spec step(event(), map(), String.t(), String.t()) :: non_neg_integer() | :none
  defp step(:deactivate, scim, id, _vm), do: elem(set_active(scim, id, false), 0)
  defp step(:reactivate, scim, id, _vm), do: elem(set_active(scim, id, true), 0)
  defp step(:delete, scim, id, _vm), do: elem(delete_user(scim, id), 0)
  defp step(:get, scim, id, _vm), do: elem(get_user(scim, id), 0)

  defp step(:expire, _scim, id, _vm) do
    expire!(id)
    :none
  end

  defp step(:run_worker, _scim, id, _vm) do
    run_worker!(id)
    :none
  end

  defp step(:complete, _scim, _id, vm) do
    complete_operations!([vm])
    :none
  end

  @spec run_worker!(String.t()) :: :ok
  defp run_worker!(id) do
    case perform_job(RetirementWorker, %{"user_id" => id}) do
      :ok -> :ok
      {:snooze, _} -> :ok
    end
  end

  @spec accept_refusal({non_neg_integer(), term()}) :: {non_neg_integer(), term()}
  defp accept_refusal({400, body}), do: {200, body}
  defp accept_refusal(other), do: other

  @spec check_response!(event(), non_neg_integer() | :none, User.t()) :: :ok
  defp check_response!(event, status, before) do
    now = Ledger.now()
    retired = not is_nil(before.deleted_at)
    due = ScimRetirement.due?(before, now)

    case event do
      :reactivate ->
        assert status == if(retired or due, do: 400, else: 200)

      :deactivate ->
        assert status == if(retired, do: 400, else: 200)

      :delete ->
        assert status == if(retired, do: 400, else: 204)

      :get ->
        hidden = retired or not is_nil(before.scim_deleted_at)
        assert status == if(hidden, do: 404, else: 200)

      _ ->
        assert status == :none
    end

    :ok
  end

  @spec check_invariants!(String.t(), String.t(), history()) :: history()
  defp check_invariants!(user_id, vm_id, history) do
    user = user!(user_id)
    now = Ledger.now()
    delete_requested = Enum.any?(Ledger.read!(Operation, vm_id: vm_id), &(&1.kind == :delete))
    finalized = not is_nil(user.deleted_at)

    # A live identity, or one still inside its grace period, never has a
    # machine deleted.
    if not finalized and not ScimRetirement.due?(user, now) do
      refute delete_requested
      assert %{archived_at: nil} = vm!(vm_id)
    end

    # Machine deletion, once begun, only ends in finalization.
    deleting = history.deleting or delete_requested
    if deleting, do: refute(user.active)

    if user.active do
      assert is_nil(deletion(user_id)) or deletion(user_id).state == :cancelled
    end

    if finalized do
      assert AccountLifecycle.owned_count(user_id) == 0
      assert to_string(user.email) == "deleted-#{user_id}@deleted.invalid"
      assert %UserDeletion{state: :completed, completed_at: %DateTime{}} = deletion(user_id)
      assert Enum.all?(suspensions(user_id), &(&1.state != :suspended))
    end

    # Finalized identities never become active or unretired again.
    if history.finalized do
      assert finalized
      refute user.active
    end

    assert length(Enum.filter(suspensions(user_id), &(&1.state == :suspended))) <= 1
    %{finalized: history.finalized or finalized, deleting: deleting}
  end
end
