defmodule Lilly.Lifecycle.Resource do
  @moduledoc "Shared durable fields for host-local Ash state machines."

  defmacro __using__(options) do
    initial = Keyword.fetch!(options, :initial)
    edges = Keyword.fetch!(options, :edges)
    states = (initial ++ Keyword.keys(edges) ++ Enum.flat_map(edges, &elem(&1, 1))) |> Enum.uniq()

    creates =
      for state <- initial do
        quote do
          create unquote(:"initialize_#{state}") do
            accept([:id, :directory, :filename, :payload])
            change(transition_state(unquote(state)))
            manual(Lilly.Lifecycle.Persist)
          end
        end
      end

    updates =
      for target <- states do
        quote do
          update unquote(:"mark_#{target}") do
            accept([:payload])
            require_atomic?(false)
            change(transition_state(unquote(target)))
            manual(Lilly.Lifecycle.Persist)
          end
        end
      end

    transitions =
      for target <- states do
        origins = for {from, targets} <- edges, target in targets, do: from

        quote do
          transition(unquote(:"mark_#{target}"), from: unquote(origins), to: unquote(target))
        end
      end

    quote do
      use Ash.Resource,
        domain: Lilly.Lifecycle,
        extensions: [AshStateMachine]

      @doc false
      @spec valid_payload?(map()) :: boolean()
      def valid_payload?(_payload), do: true

      @doc false
      @spec valid_transition?(map() | nil, map()) :: boolean()
      def valid_transition?(_previous, _next), do: true

      defoverridable valid_payload?: 1, valid_transition?: 2

      state_machine do
        initial_states(unquote(initial))
        default_initial_state(unquote(hd(initial)))

        transitions do
          (unquote_splicing(transitions))
        end
      end

      actions do
        unquote_splicing(creates)
        unquote_splicing(updates)
      end

      attributes do
        uuid_primary_key(:id, writable?: true)
        attribute(:directory, :string, allow_nil?: false, sensitive?: true)
        attribute(:filename, :string, allow_nil?: false)
        attribute(:payload, :map, allow_nil?: false, sensitive?: true)
        attribute(:revision, :integer, default: 0, allow_nil?: false)
      end
    end
  end
end
