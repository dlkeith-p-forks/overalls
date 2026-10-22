defmodule Overalls.Diagnostics.GenerateSchema do
  @moduledoc "Derive a finite vocabulary from repository-owned production source literals."
  @services ~w(marshall lilly audi brady porsche ziggy enrico galileo susan peach)
  @operations ~w(lilly.host.utility lilly.transfer.stream enrico.git.utility marshall.http marshall.agent.server_tool marshall.artifact.publish marshall.artifact.content marshall.cedar.authorize marshall.live.callback marshall.live.refresh marshall.views.read audi.http brady.http galileo.http ziggy.http porsche.ssh.dispatch peach.http enrico.http)
  @uuid ~w(event_id resource_id request_id host_id vm_id placement_id session_id user_id team_id operation_id execution_id workflow_id backup_id image_id account_id clone_id transfer_id source_id destination_id pool_id)
  @enums ~w(resource_type action previous_state next_state reason outcome state stage effect utility method mode source status operation kind phase tool namespace via view live_view)
  @numbers ~w(revision version file_count sequence duration duration_ms duration_us generation execution_epoch bytes byte_count count status_code http_status attempt tokens cached_tokens input_tokens output_tokens request_bytes response_bytes status occurred_at query_count row_count)

  # @cc [owner:ghuntley,label:verification] trace-schema-deterministic-serialization
  # Identical production vocabulary MUST serialize to identical bytes across
  # fresh BEAM processes and Mix environments; VM atom-loading order MUST NOT
  # cause the read-only schema check to report source drift.
  @spec main([binary()]) :: :ok
  def main(args) do
    root = Path.expand("../..", __DIR__)
    sources = Enum.flat_map(@services, &Path.wildcard(Path.join([root, &1, "lib/**/*.ex"])))

    initial_attributes = %{
      uuid: MapSet.new(@uuid),
      enum: MapSet.new(@enums),
      number: MapSet.new(@numbers)
    }

    {names, values, attrs} =
      Enum.reduce(sources, {%{}, MapSet.new(), initial_attributes}, &scan/2)

    names =
      Enum.reduce(@operations, names, fn name, result ->
        service = name |> String.split(".") |> hd()
        Map.update(result, service, [name], &[name | &1])
      end)

    services =
      @services
      |> Enum.sort()
      |> Enum.map(&{&1, names |> Map.get(&1, []) |> Enum.uniq() |> Enum.sort()})
      |> Jason.OrderedObject.new()

    schema =
      Jason.OrderedObject.new(
        services: services,
        uuid_attributes: attrs.uuid |> MapSet.to_list() |> Enum.sort(),
        enum_attributes: attrs.enum |> MapSet.to_list() |> Enum.sort(),
        numeric_attributes: attrs.number |> MapSet.to_list() |> Enum.sort(),
        enum_values: values |> MapSet.to_list() |> Enum.sort()
      )

    body = Jason.encode!(schema, pretty: true) <> "\n"
    target = Path.join(__DIR__, "priv/trace-schema.json")

    case args do
      ["--check"] ->
        if File.read!(target) != body,
          do: raise("review trace vocabulary and run mix run generate_schema.exs")

        :ok

      [] ->
        File.write!(target, body)

      _ ->
        raise("expected --check or no arguments")
    end
  end

  @type accumulator ::
          {%{binary() => [binary()]}, MapSet.t(binary()),
           %{uuid: MapSet.t(binary()), enum: MapSet.t(binary()), number: MapSet.t(binary())}}
  @spec scan(binary(), accumulator()) :: accumulator()
  defp scan(path, accumulator) do
    service = path |> Path.relative_to(Path.expand("../..", __DIR__)) |> String.split("/") |> hd()
    ast = path |> File.read!() |> Code.string_to_quoted!(columns: true)

    {_, result} =
      Macro.prewalk(ast, accumulator, fn
        {:defevent, _, [name, opts]} = node, {names, values, attrs} when is_binary(name) ->
          attrs =
            Enum.reduce(Keyword.get(opts, :metadata, []), attrs, fn {key, type}, current ->
              base =
                case type do
                  {base, :optional} -> base
                  other -> other
                end

              category =
                case base do
                  :uuid -> :uuid
                  :atom -> :enum
                  {:enum, _} -> :enum
                  integer when integer in [:int, :int64] -> :number
                  _ -> nil
                end

              if category,
                do: Map.update!(current, category, &MapSet.put(&1, Atom.to_string(key))),
                else: current
            end)

          {node, {Map.update(names, service, [name], &[name | &1]), values, attrs}}

        {:use, _, [{:__aliases__, _, [:Lilly, :Lifecycle, :Resource]}, opts]} = node,
        {names, values, attrs} ->
          initial = Keyword.fetch!(opts, :initial)
          edges = Keyword.fetch!(opts, :edges)
          states = initial ++ Keyword.keys(edges) ++ Enum.flat_map(edges, &elem(&1, 1))

          derived =
            Enum.map(initial, &("initialize_" <> Atom.to_string(&1))) ++
              Enum.map(states, &("mark_" <> Atom.to_string(&1)))

          {node, {names, Enum.reduce(derived, values, &MapSet.put(&2, &1)), attrs}}

        value, {names, values, attrs} when is_atom(value) ->
          string = Atom.to_string(value)

          if String.match?(string, ~r/\A[a-z][a-z0-9_]{0,63}\z/),
            do: {value, {names, MapSet.put(values, string), attrs}},
            else: {value, {names, values, attrs}}

        node, current ->
          {node, current}
      end)

    result
  end
end

Overalls.Diagnostics.GenerateSchema.main(System.argv())
