defmodule Marshall.GitHub.StateMachineTest do
  use ExUnit.Case, async: true
  import Hegel
  import Hegel.Gen
  alias Marshall.Authorization.SystemActor
  alias Marshall.GitHub.{AuthorizationAttempt, Connection, RefreshAttempt}

  @type graph :: %{atom() => %{atom() => atom()}}

  property "connection histories cannot publish before refresh or resurrect after disconnect" do
    graph = %{
      disconnected: %{
        connect: :connected,
        disconnect: :revoking,
        invalidate_restored: :reconnect_required
      },
      connected: %{
        drain: :draining,
        require_reconnect: :reconnect_required,
        disconnect: :revoking,
        invalidate_restored: :reconnect_required
      },
      draining: %{
        start_refresh: :refreshing,
        require_reconnect: :reconnect_required,
        disconnect: :revoking,
        invalidate_restored: :reconnect_required
      },
      refreshing: %{
        refresh: :connected,
        require_reconnect: :reconnect_required,
        disconnect: :revoking,
        invalidate_restored: :reconnect_required
      },
      reconnect_required: %{
        connect: :connected,
        require_reconnect: :reconnect_required,
        disconnect: :revoking,
        invalidate_restored: :reconnect_required
      },
      revoking: %{
        revoked: :disconnected,
        disconnect: :revoking,
        invalidate_restored: :reconnect_required
      }
    }

    histories(Connection, graph, :disconnected)
  end

  property "authorization state is consumed at most once" do
    graph = %{
      pending: %{exchange: :exchanging, fail: :failed, cancel: :cancelled},
      exchanging: %{consume: :consumed, fail: :failed, cancel: :cancelled},
      consumed: %{},
      failed: %{},
      cancelled: %{}
    }

    histories(AuthorizationAttempt, graph, :pending)
  end

  property "a submitted refresh can stage once and never be resubmitted" do
    graph = %{
      pending: %{submit: :submitted, fail: :failed},
      submitted: %{stage: :staged, fail: :failed},
      staged: %{finish: :finished, fail: :failed},
      finished: %{},
      failed: %{}
    }

    histories(RefreshAttempt, graph, :pending)
  end

  test "progress actions cannot accept a phase or bypass the refresh generation fence" do
    refute change(struct(Connection, phase: :connected), :authorize, %{phase: :refreshing}).valid?
    refute change(struct(Connection, phase: :connected), :refresh).valid?
    refute change(struct(Connection, phase: :revoking), :connect).valid?
    refute change(struct(RefreshAttempt, phase: :submitted), :submit).valid?
    refute change(struct(AuthorizationAttempt, phase: :consumed), :exchange).valid?
  end

  @spec histories(module(), graph(), atom()) :: atom()
  defp histories(resource, graph, initial) do
    actions = graph |> Map.values() |> Enum.flat_map(&Map.keys/1) |> Enum.uniq()
    history = Hegel.draw("history", list_of(member_of(actions), max_length: 60))

    Enum.reduce(history, initial, fn action, state ->
      expected = graph |> Map.fetch!(state) |> Map.get(action)
      changeset = change(struct(resource, phase: state), action)
      assert changeset.valid? == not is_nil(expected)

      if expected do
        assert Ash.Changeset.get_attribute(changeset, :phase) == expected
        expected
      else
        state
      end
    end)
  end

  @spec change(struct(), atom(), map()) :: Ash.Changeset.t()
  defp change(record, action, attrs \\ %{}),
    do: Ash.Changeset.for_update(record, action, attrs, actor: SystemActor.compute())
end
