defmodule OverallsAntithesis.SDK do
  @moduledoc "Harness-only Antithesis fallback SDK. Assertions are literal compile-time callsites."
  import Bitwise

  alias OverallsAntithesis.SDK.{Details, Property, Writer}

  @type delivery :: Writer.delivery()
  @type catalog_result :: {:ok, [Property.t()]} | {:error, :invalid_catalog}

  defmacro __before_compile__(env) do
    properties = env.module |> Module.get_attribute(:antithesis_assertions) |> Enum.reverse()

    quote do
      @doc false
      @spec __antithesis_catalog__() :: [OverallsAntithesis.SDK.Property.t()]
      def __antithesis_catalog__, do: unquote(Macro.escape(properties))
    end
  end

  defmacro always(message, condition, details \\ nil),
    do: assertion(__CALLER__, :always, message, condition, details)

  defmacro always_or_unreachable(message, condition, details \\ nil),
    do: assertion(__CALLER__, :always_or_unreachable, message, condition, details)

  defmacro sometimes(message, condition, details \\ nil),
    do: assertion(__CALLER__, :sometimes, message, condition, details)

  defmacro reachable(message, details \\ nil),
    do: assertion(__CALLER__, :reachable, message, true, details)

  defmacro unreachable(message, details \\ nil),
    do: assertion(__CALLER__, :unreachable, message, false, details)

  @doc "Returns the immutable union of property callsites in the specified modules."
  @spec catalog([module()]) :: catalog_result()
  def catalog(modules) when is_list(modules) do
    with true <- Enum.all?(modules, &is_atom/1),
         true <-
           Enum.all?(
             modules,
             &(Code.ensure_loaded?(&1) and function_exported?(&1, :__antithesis_catalog__, 0))
           ) do
      properties = Enum.flat_map(modules, & &1.__antithesis_catalog__())
      messages = Enum.map(properties, & &1.message)

      if Enum.all?(properties, &valid_property?/1) and
           length(messages) == length(Enum.uniq(messages)) do
        {:ok, Enum.sort_by(properties, & &1.message)}
      else
        {:error, :invalid_catalog}
      end
    else
      _ -> {:error, :invalid_catalog}
    end
  end

  def catalog(_), do: {:error, :invalid_catalog}

  @doc "Write the full catalog at startup before any test evaluation or setup signal."
  @spec declare_catalog([module()]) :: :written | :disabled | {:error, atom()}
  def declare_catalog(modules) do
    with {:ok, properties} <- catalog(modules) do
      Enum.reduce_while(properties, :written, fn property, _acc ->
        case Writer.submit(
               Property.wire(property, false, false, nil),
               "declare:" <> property.message
             ) do
          result when result in [:written, :duplicate] -> {:cont, :written}
          result -> {:halt, result}
        end
      end)
    end
  end

  @doc "Export reviewed catalog metadata from compiled literal callsites for image validation."
  @spec export_catalog([module()], binary()) :: :ok | {:error, atom()}
  def export_catalog(modules, path) when is_binary(path) do
    with {:ok, properties} <- catalog(modules),
         true <- Path.type(path) == :absolute,
         :ok <-
           File.write(
             path,
             Jason.encode!(Enum.map(properties, &Property.wire(&1, false, false, nil)))
           ) do
      :ok
    else
      false -> {:error, :invalid_catalog}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Emit an already-observed condition. The macro owns the literal descriptor."
  @spec evaluate(Property.t(), boolean(), Details.t() | nil) :: delivery()
  def evaluate(%Property{} = property, condition, details)
      when is_boolean(condition) and (is_nil(details) or is_struct(details, Details)) do
    cond do
      not valid_property?(property) or not registered_property?(property) ->
        {:error, :invalid}

      not is_nil(details) and not Details.valid?(details) ->
        {:error, :invalid}

      property.kind == :reachable and condition != true ->
        {:error, :invalid}

      property.kind == :unreachable and condition != false ->
        {:error, :invalid}

      true ->
        Writer.submit(
          Property.wire(property, true, condition, details),
          "eval:" <> property.message <> ":" <> to_string(condition)
        )
    end
  end

  def evaluate(_, _, _), do: {:error, :invalid}

  # @cc [owner:ghuntley,label:protocol] sdk-single-explicit-setup
  # Only the readiness coordinator may call this function after declaring the
  # complete catalog and proving readiness; SDK startup MUST NOT autoemit setup.
  @doc "Explicit lifecycle signal; call exactly once after complete harness readiness."
  @spec setup_complete() :: delivery()
  def setup_complete do
    Writer.submit(%{"antithesis_setup" => %{"status" => "complete"}}, "setup:complete")
  end

  @spec status() :: :ready | :busy | :poisoned | :unavailable | :disabled
  def status, do: Writer.status()

  # @cc [owner:ghuntley,label:verification] sdk-direct-random-draws
  # Each choice MUST read fresh bytes from /dev/urandom and use rejection sampling;
  # returned bytes MUST NOT seed a stateful PRNG or bias a non-power-of-two bound.
  @doc "Choose directly from the intercepted random device with unbiased rejection."
  @spec choose(nonempty_list(item)) :: {:ok, item} | {:error, :random_unavailable} when item: var
  def choose([_ | _] = choices) do
    count = length(choices)
    bytes = max(1, div(bit_length(count - 1) + 7, 8))
    modulus = 1 <<< (bytes * 8)
    ceiling = modulus - rem(modulus, count)

    case draw_index(count, bytes, ceiling, 0) do
      {:ok, index} -> {:ok, Enum.at(choices, index)}
      error -> error
    end
  end

  def choose(_), do: {:error, :random_unavailable}

  @spec draw_index(pos_integer(), pos_integer(), pos_integer(), non_neg_integer()) ::
          {:ok, non_neg_integer()} | {:error, :random_unavailable}
  defp draw_index(_count, _bytes, _ceiling, attempts) when attempts >= 128,
    do: {:error, :random_unavailable}

  defp draw_index(count, bytes, ceiling, attempts) do
    case File.open("/dev/urandom", [:read, :binary], fn device -> IO.binread(device, bytes) end) do
      {:ok, binary} when is_binary(binary) and byte_size(binary) == bytes ->
        value = :binary.decode_unsigned(binary)

        if value < ceiling,
          do: {:ok, rem(value, count)},
          else: draw_index(count, bytes, ceiling, attempts + 1)

      _ ->
        {:error, :random_unavailable}
    end
  end

  @spec bit_length(non_neg_integer()) :: pos_integer()
  defp bit_length(0), do: 1
  defp bit_length(value), do: value |> Integer.digits(2) |> length()

  @spec valid_property?(Property.t()) :: boolean()
  defp valid_property?(%Property{} = property) do
    property.kind in [:always, :always_or_unreachable, :sometimes, :reachable, :unreachable] and
      valid_literal?(property.message) and valid_literal?(property.module) and
      valid_literal?(property.function) and valid_literal?(property.file) and
      is_integer(property.line) and property.line > 0
  end

  @spec registered_property?(Property.t()) :: boolean()
  defp registered_property?(%Property{} = property) do
    module = String.to_existing_atom(property.module)

    Code.ensure_loaded?(module) and function_exported?(module, :__antithesis_catalog__, 0) and
      Enum.member?(module.__antithesis_catalog__(), property)
  rescue
    ArgumentError -> false
  end

  @spec valid_literal?(term()) :: boolean()
  defp valid_literal?(value) do
    is_binary(value) and byte_size(value) in 1..256 and String.valid?(value) and
      not String.contains?(value, ["\n", "\r", "\0"])
  end

  @spec assertion(Macro.Env.t(), Property.kind(), Macro.t(), Macro.t(), Macro.t()) :: Macro.t()
  defp assertion(env, kind, message, condition, details) do
    unless is_binary(message) and valid_literal?(message) do
      raise ArgumentError, "Antithesis assertion message must be a short literal UTF-8 string"
    end

    module = env.module || raise ArgumentError, "Antithesis assertion requires a module callsite"

    function =
      case env.function do
        {name, arity} -> "#{name}/#{arity}"
        nil -> "module"
      end

    file = Path.relative_to(env.file, File.cwd!())

    property = %Property{
      kind: kind,
      message: message,
      module: Atom.to_string(module),
      function: function,
      file: file,
      line: env.line
    }

    unless Module.has_attribute?(module, :antithesis_assertions) do
      Module.register_attribute(module, :antithesis_assertions, accumulate: true)
      Module.put_attribute(module, :before_compile, __MODULE__)
    end

    existing = Module.get_attribute(module, :antithesis_assertions)

    if Enum.any?(existing, &(&1.message == message)) do
      raise ArgumentError, "duplicate Antithesis assertion message: #{message}"
    end

    Module.put_attribute(module, :antithesis_assertions, property)

    quote do
      OverallsAntithesis.SDK.evaluate(
        unquote(Macro.escape(property)),
        unquote(condition),
        unquote(details)
      )
    end
  end
end
