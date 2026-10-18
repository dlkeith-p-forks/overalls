defmodule Peach.Control do
  @spec snapshot(map()) :: {:ok, map()} | {:error, term()}
  def snapshot(binding) do
    OverallsProtocol.Control.Client.request(
      Peach.Control.Client,
      "peach.snapshot",
      %{"version" => 1, "binding" => binding},
      2_000
    )
  end
end
