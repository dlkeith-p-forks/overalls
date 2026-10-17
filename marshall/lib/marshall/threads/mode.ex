defmodule Marshall.Threads.Mode do
  @moduledoc "Validated user-facing agent modes and their runtime model settings."

  @type t :: :low | :medium | :high | :ultra
  @modes [:low, :medium, :high, :ultra]

  @spec values() :: [t()]
  def values, do: @modes

  @spec parse(atom() | String.t()) :: {:ok, t()} | {:error, :invalid_mode}
  def parse(mode) when mode in @modes, do: {:ok, mode}

  def parse(mode) when is_binary(mode) do
    case mode do
      "low" -> {:ok, :low}
      "medium" -> {:ok, :medium}
      "high" -> {:ok, :high}
      "ultra" -> {:ok, :ultra}
      _ -> {:error, :invalid_mode}
    end
  end

  def parse(_), do: {:error, :invalid_mode}

  @spec model(t()) :: String.t()
  def model(mode) when mode in @modes do
    settings()
    |> Map.get(mode, default_models()[mode])
    |> Map.fetch!(:model)
  end

  @spec reasoning_effort(t()) :: atom() | nil
  def reasoning_effort(mode) when mode in @modes do
    settings()
    |> Map.get(mode, default_models()[mode])
    |> Map.get(:reasoning_effort)
  end

  @spec default() :: t()
  def default, do: :medium

  @spec settings() :: %{optional(t()) => %{model: String.t(), reasoning_effort: atom() | nil}}
  defp settings do
    case Application.get_env(:marshall, :thread_modes, %{}) do
      settings when is_map(settings) -> settings
      settings when is_list(settings) -> Map.new(settings)
      _ -> %{}
    end
  end

  defp default_models do
    %{
      low: %{model: "gpt-6-sol", reasoning_effort: :low},
      medium: %{model: "gpt-6-sol", reasoning_effort: :medium},
      high: %{model: "gpt-6-sol", reasoning_effort: :high},
      ultra: %{model: "gpt-6-sol", reasoning_effort: :ultra}
    }
  end
end
