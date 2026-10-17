defmodule Marshall.Threads.Title do
  @moduledoc "Bounded thread title generation with a deterministic safe fallback."

  @type generator :: (String.t() -> {:ok, String.t()} | {:error, term()})

  @spec generate(String.t()) :: String.t()
  def generate(objective) when is_binary(objective) do
    generator = Application.get_env(:marshall, :thread_title_generator, &fallback/1)

    case generator.(objective) do
      {:ok, title} when is_binary(title) -> normalize(title, objective)
      _ -> fallback(objective)
    end
  end

  @spec fallback(String.t()) :: String.t()
  def fallback(objective) do
    objective
    |> String.split(~r/[.!?\n]+/, trim: true)
    |> List.first()
    |> Kernel.||(objective)
    |> normalize(objective)
  end

  defp normalize(value, fallback) do
    value = value |> String.trim() |> String.replace(~r/\s+/, " ") |> String.slice(0, 120)
    if value == "", do: String.slice(String.trim(fallback), 0, 120), else: value
  end
end
