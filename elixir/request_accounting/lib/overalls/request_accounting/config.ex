defmodule Overalls.RequestAccounting.Config do
  @moduledoc """
  Validated configuration for a supervised request-accounting producer.

  Environment discovery lives here so the producer process only receives an
  explicit, validated configuration.
  """

  @enforce_keys [:name, :socket, :directory]
  defstruct [:name, :socket, :directory]

  @typedoc "Validated producer configuration."
  @type t :: %__MODULE__{name: atom(), socket: binary(), directory: binary()}
  @type environment_result :: :ignore | {:ok, t()} | {:error, :invalid_measurement_configuration}

  # @cc [owner:ghuntley,label:deployment;reliability] producer-validated-configuration
  # Configuration MUST require a named producer and both absolute measurement
  # paths. Invalid or partial configuration MUST fail before supervision.
  @spec new(keyword()) :: {:ok, t()} | {:error, :invalid_measurement_configuration}
  def new(opts) when is_list(opts) do
    if Keyword.keyword?(opts) and Enum.sort(Keyword.keys(opts)) == [:directory, :name, :socket] do
      validate(%__MODULE__{
        name: Keyword.fetch!(opts, :name),
        socket: Keyword.fetch!(opts, :socket),
        directory: Keyword.fetch!(opts, :directory)
      })
    else
      {:error, :invalid_measurement_configuration}
    end
  end

  @doc "Constructs a configuration or raises for invalid options."
  @spec new!(keyword()) :: t()
  def new!(opts) do
    case new(opts) do
      {:ok, config} ->
        config

      {:error, :invalid_measurement_configuration} ->
        raise ArgumentError, "invalid request accounting configuration"
    end
  end

  @doc "Checks direct structs before they cross the producer supervision boundary."
  @spec validate(t()) :: {:ok, t()} | {:error, :invalid_measurement_configuration}
  def validate(%__MODULE__{} = config) do
    if is_atom(config.name) and not is_nil(config.name) and
         valid_path?(config.socket) and valid_path?(config.directory) do
      {:ok, config}
    else
      {:error, :invalid_measurement_configuration}
    end
  end

  @spec validate!(t()) :: t()
  def validate!(config) do
    case validate(config) do
      {:ok, config} ->
        config

      {:error, :invalid_measurement_configuration} ->
        raise ArgumentError, "invalid request accounting configuration"
    end
  end

  # @cc [owner:ghuntley,label:deployment] optional-producer-startup
  # Only absent socket and marker configuration MAY disable the producer.
  # A partial configuration MUST retain the explicit configured failure path.
  # A non-empty suffix MUST select only that source's suffixed variables, so
  # several sources in one unit never read one another's recorder.
  @spec from_environment(atom(), binary()) :: environment_result()
  def from_environment(name, suffix \\ "") when is_atom(name) and is_binary(suffix) do
    unless Regex.match?(~r/\A(_[A-Z0-9]+)*\z/, suffix),
      do: raise(ArgumentError, "invalid request accounting environment suffix")

    opts = [
      name: name,
      socket: System.get_env("OVERALLS_REQUEST_ACCOUNTING_SOCKET" <> suffix),
      directory: System.get_env("OVERALLS_REQUEST_ACCOUNTING_MARKER_DIRECTORY" <> suffix)
    ]

    case {opts[:socket], opts[:directory]} do
      {nil, nil} -> :ignore
      _ -> new(opts)
    end
  end

  @spec valid_path?(term()) :: boolean()
  defp valid_path?(path) when is_binary(path),
    do:
      byte_size(path) > 1 and String.starts_with?(path, "/") and String.valid?(path) and
        not String.contains?(path, <<0>>)

  defp valid_path?(_path), do: false
end
