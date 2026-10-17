defmodule Overalls.Diagnostics.Events.Catalog do
  @moduledoc """
  Compile-time machinery for the reviewed structured-event catalog.

  `use` this module in an application event catalog and declare each reviewed
  event with `defevent/2`. The generated `emit/2` macro validates the event
  name and metadata keys when the *caller* compiles, so an unknown event or a
  typo'd metadata key cannot compile. Metadata values are validated at runtime
  against the declared shape: violations raise in `:dev`/`:test` and drop the
  offending field in `:prod`, so no unvalidated value can reach a log
  destination. Log message text is fixed by the catalog; call sites never
  interpolate payloads.
  """

  @type field_type :: :uuid | :atom | :int | :int64 | :pid | {:enum, [atom()]}
  @type delivery :: :routine | :custody

  @typedoc "The reviewed projection of a catalogued diagnostic event."
  @type projection :: %{
          required(:event) => binary(),
          required(:service) => Overalls.Diagnostics.service(),
          required(:level) => :info | :warning | :error,
          required(:message) => binary(),
          required(:metadata) => keyword(field_type() | {field_type(), :optional}),
          required(:log?) => boolean(),
          required(:trace?) => boolean(),
          required(:delivery) => delivery()
        }
  @doc false
  @spec enum_type?(term()) :: boolean()
  def enum_type?({:enum, values}) when is_list(values),
    do:
      values != [] and Enum.all?(values, &is_atom/1) and Enum.uniq(values) == values and
        nil not in values

  def enum_type?(_), do: false

  @doc false
  # @cc [owner:ghuntley,label:security] catalog-projection-closed-selection
  # A catalog projection MUST expose independent reviewed log and trace
  # and delivery decisions; producers MUST NOT infer trace eligibility or
  # custody from message text, event names or arbitrary metadata.
  @spec projection(module(), binary()) :: projection() | nil
  def projection(catalog, event) when is_atom(catalog) and is_binary(event) do
    with {:module, _module} <- Code.ensure_loaded(catalog),
         true <- function_exported?(catalog, :__projection__, 1) do
      catalog.__projection__(event)
    else
      _ -> nil
    end
  end

  @doc false
  @spec log_event?(module(), binary()) :: boolean()
  def log_event?(catalog, event), do: match?(%{log?: true}, projection(catalog, event))

  @doc false
  @spec trace_event?(module(), binary()) :: boolean()
  def trace_event?(catalog, event), do: match?(%{trace?: true}, projection(catalog, event))

  @doc false
  @spec shape?(field_type() | {field_type(), :optional}, term()) :: boolean()
  def shape?({type, :optional}, value), do: is_nil(value) or shape?(type, value)
  def shape?(:uuid, value), do: Overalls.Diagnostics.Schema.uuid?(value)

  def shape?(:atom, value),
    do: is_atom(value) and value != nil and Overalls.Diagnostics.Schema.enum?(value)

  def shape?({:enum, values}, value), do: value in values
  def shape?(:int, value), do: is_integer(value) and value >= 0 and value <= 2_147_483_647

  def shape?(:int64, value),
    do: is_integer(value) and value >= 0 and value <= 9_223_372_036_854_775_807

  def shape?(:pid, value), do: is_pid(value) or (is_integer(value) and value > 0)
  def shape?(_, _), do: false

  @doc false
  @spec safe_metadata(keyword(field_type() | {field_type(), :optional}), map()) :: map()
  def safe_metadata(declared, metadata) do
    Map.new(
      for {key, type} <- declared,
          value = Map.get(metadata, key),
          not is_nil(value),
          shape?(type, value),
          do: {key, value}
    )
  end

  @doc false
  # @cc [owner:ghuntley,label:security] catalog-strict-adapter-validation
  # Dynamic adapters MUST reject unknown events, undeclared or duplicate keys,
  # missing required fields and invalid values as a whole. Invalid fields MUST
  # NOT be silently discarded before custody submission.
  @spec validate(module(), binary(), map() | keyword()) ::
          {:ok, map()} | {:error, :invalid}
  def validate(catalog, event, metadata)
      when is_atom(catalog) and is_binary(event) and (is_map(metadata) or is_list(metadata)) do
    with %{metadata: declared} <- projection(catalog, event),
         {:ok, values} <- metadata_map(metadata),
         true <- valid_keys?(values, declared),
         true <- required_keys_present?(values, declared),
         true <-
           Enum.all?(values, fn {key, value} -> shape?(Keyword.get(declared, key), value) end) do
      {:ok, Map.filter(values, fn {_key, value} -> not is_nil(value) end)}
    else
      _ -> {:error, :invalid}
    end
  end

  def validate(_, _, _), do: {:error, :invalid}

  @spec metadata_map(map() | keyword()) :: {:ok, map()} | {:error, :invalid}
  defp metadata_map(values) when is_map(values), do: {:ok, values}

  defp metadata_map(values) when is_list(values) do
    if Keyword.keyword?(values) and length(values) == length(Enum.uniq(Keyword.keys(values))),
      do: {:ok, Map.new(values)},
      else: {:error, :invalid}
  end

  @spec valid_keys?(map(), keyword()) :: boolean()
  defp valid_keys?(values, declared),
    do: Enum.all?(Map.keys(values), &Keyword.has_key?(declared, &1))

  @spec required_keys_present?(map(), keyword()) :: boolean()
  defp required_keys_present?(values, declared) do
    Enum.all?(declared, fn
      {_key, {_type, :optional}} -> true
      {key, _type} -> Map.has_key?(values, key) and not is_nil(values[key])
    end)
  end

  defmacro __using__(opts) do
    quote do
      import unquote(__MODULE__), only: [defevent: 2]
      @events_service unquote(Keyword.fetch!(opts, :service))
      Module.register_attribute(__MODULE__, :event_specs, accumulate: true)
      @before_compile unquote(__MODULE__)
    end
  end

  defmacro defevent(name, opts) when is_binary(name) do
    quote bind_quoted: [name: name, opts: opts] do
      level = Keyword.get(opts, :level, :info)
      message = Keyword.fetch!(opts, :message)
      metadata = Keyword.get(opts, :metadata, [])
      log? = Keyword.get(opts, :log, true)
      trace? = Keyword.get(opts, :trace, true)
      delivery = Keyword.get(opts, :delivery, :routine)

      unless level in [:info, :warning, :error] and is_binary(message) and
               Keyword.keyword?(metadata) and is_boolean(log?) and is_boolean(trace?) and
               delivery in [:routine, :custody] do
        raise ArgumentError, "invalid structured event declaration"
      end

      keys = Keyword.keys(metadata)
      if Enum.uniq(keys) != keys, do: raise(ArgumentError, "duplicate event metadata declaration")

      if delivery == :custody and
           (not trace? or Keyword.get(metadata, :event_id) != :uuid or
              Keyword.get(metadata, :occurred_at) != :int64) do
        raise ArgumentError,
              "custody event declarations require tracing, event_id: :uuid and occurred_at: :int64"
      end

      for {key, type} <- metadata do
        valid =
          type in [:uuid, :atom, :int, :int64, :pid] or
            (is_tuple(type) and tuple_size(type) == 2 and elem(type, 1) == :optional and
               (elem(type, 0) in [:uuid, :atom, :int, :int64, :pid] or
                  Overalls.Diagnostics.Events.Catalog.enum_type?(elem(type, 0)))) or
            Overalls.Diagnostics.Events.Catalog.enum_type?(type)

        unless valid do
          raise ArgumentError,
                "event #{inspect(name)} key #{inspect(key)} has unsupported type #{inspect(type)}"
        end

        if key == :event do
          raise ArgumentError,
                "event #{inspect(name)} cannot declare metadata key :event; " <>
                  "it is reserved for the catalogued event name"
        end
      end

      @event_specs {name, level, message, metadata, log?, trace?, delivery}
    end
  end

  defmacro __before_compile__(env) do
    service = Module.get_attribute(env.module, :events_service)
    specs = env.module |> Module.get_attribute(:event_specs) |> Enum.reverse()

    if specs == [] do
      raise "event catalog #{inspect(env.module)} declares no events"
    end

    names = Enum.map(specs, &elem(&1, 0))

    if Enum.uniq(names) != names,
      do: raise(ArgumentError, "duplicate structured event declaration")

    catalog =
      Map.new(specs, fn {name, level, message, metadata, log?, trace?, delivery} ->
        {name,
         %{
           service: service,
           level: level,
           message: message,
           metadata: metadata,
           log?: log?,
           trace?: trace?,
           delivery: delivery
         }}
      end)

    catalog_ast = Macro.escape(catalog)

    quote do
      require Logger

      @doc false
      @spec __catalog__() :: map()
      def __catalog__, do: unquote(catalog_ast)

      @doc false
      @spec __projection__(binary()) :: Overalls.Diagnostics.Events.Catalog.projection() | nil
      def __projection__(event) when is_binary(event) do
        case Map.get(unquote(catalog_ast), event) do
          nil -> nil
          spec -> Map.put(spec, :event, event)
        end
      end

      # @cc [owner:ghuntley,label:security] event-catalog-closed-surface
      # emit/2 MUST only accept catalogued event names and metadata keys; the
      # macro rejects unknown names/keys at caller compile time and runtime
      # validation drops (prod) or raises (dev/test) on shape violations, so
      # no unvalidated value can reach a log destination.
      defmacro emit(event, meta) when is_binary(event) and is_list(meta) do
        unless Keyword.keyword?(meta),
          do: raise(ArgumentError, "event metadata must be a literal keyword list")

        keys = Keyword.keys(meta)

        if Enum.uniq(keys) != keys,
          do: raise(ArgumentError, "duplicate structured event emission key")

        catalog = unquote(catalog_ast)
        module = __MODULE__

        unless Map.has_key?(catalog, event) do
          raise ArgumentError,
                "unknown structured event #{inspect(event)}: add a defevent entry to " <>
                  inspect(module) <>
                  " or use an existing event. Known events: " <>
                  inspect(Enum.sort(Map.keys(catalog)))
        end

        spec = Map.fetch!(catalog, event)
        declared = spec.metadata

        {known, unknown} =
          Enum.split_with(meta, fn {key, _value} -> Keyword.has_key?(declared, key) end)

        unless unknown == [] do
          raise ArgumentError,
                "event " <>
                  inspect(event) <>
                  " does not accept metadata keys " <>
                  inspect(Enum.sort(Enum.map(unknown, &elem(&1, 0)))) <>
                  ". Allowed keys: " <> inspect(Keyword.keys(declared))
        end

        missing =
          declared
          |> Enum.reject(fn {_k, type} -> is_tuple(type) and elem(type, 1) == :optional end)
          |> Enum.map(&elem(&1, 0))
          |> Kernel.--(Enum.map(known, &elem(&1, 0)))

        unless missing == [] do
          raise ArgumentError,
                "event " <> inspect(event) <> " requires metadata keys " <> inspect(missing)
        end

        validated =
          for {key, value_ast} <- meta do
            declared_type = Keyword.fetch!(declared, key)
            optional? = is_tuple(declared_type) and elem(declared_type, 1) == :optional
            type = if optional?, do: elem(declared_type, 0), else: declared_type

            validated_value =
              quote do
                unquote(module).__validate__(
                  unquote(Macro.escape(type)),
                  unquote(value_ast),
                  unquote(optional?)
                )
              end

            {key, validated_value}
          end

        quote do
          unquote(module).__emit__(
            unquote(event),
            unquote(spec.level),
            unquote(spec.message),
            unquote(validated)
          )
        end
      end

      defmacro emit(event, meta) do
        module = __MODULE__

        raise ArgumentError,
              inspect(module) <>
                ".emit/2 requires a literal event string and literal keyword metadata, got: " <>
                Macro.to_string(event) <> " " <> Macro.to_string(meta)
      end

      @drop_mode Mix.env() == :prod

      @doc false
      @spec __emit__(binary(), :info | :warning | :error, binary(), keyword()) :: :ok
      def __emit__(event, level, message, metadata)
          when is_binary(event) and level in [:info, :warning, :error] and is_binary(message) and
                 is_list(metadata) do
        metadata = Enum.reject(metadata, fn {_k, v} -> v == :drop end)

        case Overalls.Diagnostics.Events.Catalog.projection(__MODULE__, event) do
          %{log?: false} = projection ->
            Overalls.Diagnostics.Tracing.emit_event(projection, metadata, fn -> :ok end)

          %{} = projection ->
            Overalls.Diagnostics.Tracing.emit_event(
              projection,
              metadata,
              fn ->
                context = Overalls.Diagnostics.Context.event_log_context(projection, metadata)
                Logger.log(level, message, [event: event] ++ metadata ++ Map.to_list(context))
                :ok
              end
            )

          _ ->
            Logger.log(level, message, [event: event] ++ metadata)
        end

        :ok
      end

      @doc false
      @spec __validate__(Overalls.Diagnostics.Events.Catalog.field_type(), term(), boolean()) ::
              term()
      def __validate__(type, nil, optional?) when type in [:uuid, :atom, :int, :int64, :pid] do
        if optional?, do: :drop, else: invalid(type)
      end

      def __validate__(:uuid, value, _optional) do
        if is_binary(value) and uuid?(value), do: value, else: invalid(:uuid)
      end

      def __validate__(:atom, value, _optional) do
        if is_atom(value) and Overalls.Diagnostics.Schema.enum?(value),
          do: value,
          else: invalid(:atom)
      end

      def __validate__({:enum, _values} = type, nil, optional?) do
        if optional?, do: :drop, else: invalid(type)
      end

      def __validate__({:enum, values} = type, value, _optional) do
        if value in values, do: value, else: invalid(type)
      end

      def __validate__(:int64, value, _optional) do
        if is_integer(value) and value >= 0 and value <= 9_223_372_036_854_775_807,
          do: value,
          else: invalid(:int64)
      end

      def __validate__(:pid, value, _optional) do
        if is_pid(value) or (is_integer(value) and value > 0),
          do: value,
          else: invalid(:pid)
      end

      def __validate__(:int, value, _optional) do
        if is_integer(value) and value >= 0 and value <= 2_147_483_647,
          do: value,
          else: invalid(:int)
      end

      if @drop_mode do
        defp invalid(_type), do: :drop
      else
        defp invalid(_type) do
          raise ArgumentError,
                "structured event metadata value rejected by shape validation (offending value redacted)"
        end
      end

      defp uuid?(value) when is_binary(value) do
        case String.split(value, "-") do
          [a, b, c, d, e] ->
            byte_size(a) == 8 and byte_size(b) == 4 and byte_size(c) == 4 and
              byte_size(d) == 4 and byte_size(e) == 12 and
              Enum.all?([a, b, c, d, e], &hex_part?/1)

          _ ->
            false
        end
      end

      defp hex_part?(part) do
        part != "" and String.match?(part, ~r/\A[0-9A-Fa-f]+\z/)
      end
    end
  end
end
