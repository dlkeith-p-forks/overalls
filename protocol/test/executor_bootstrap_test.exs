defmodule OverallsProtocol.ExecutorBootstrapTest do
  use ExUnit.Case, async: true
  import Hegel
  import Hegel.Gen
  alias OverallsProtocol.ExecutorBootstrap

  @spec fixture() :: map()
  defp fixture do
    platforms =
      Map.new(~w(linux-amd64 windows-amd64 freebsd-amd64 illumos-amd64), fn platform ->
        {platform,
         %{
           "path" =>
             platform <> if(platform == "windows-amd64", do: "/executor.exe", else: "/executor"),
           "bytes" => 1,
           "sha256" => String.duplicate("a", 64)
         }}
      end)

    %{"version" => 1, "platforms" => platforms}
  end

  test "fixed platform inventory never carries activation authority" do
    assert {:ok, release} = ExecutorBootstrap.decode(fixture())
    assert map_size(release.platforms) == 4
    refute Map.has_key?(release, :executor_id)

    for invalid <- [
          nil,
          %{},
          Map.put(fixture(), "version", 2),
          Map.put(fixture(), "token", "bounded")
        ] do
      assert {:error, :invalid_executor_bootstrap} = ExecutorBootstrap.decode(invalid)
    end
  end

  property "generated platform mutations refuse caller-selected paths, sizes and fields" do
    platform =
      draw(
        "platform",
        one_of(Enum.map(~w(linux-amd64 windows-amd64 freebsd-amd64 illumos-amd64), &constant/1))
      )

    mutation = draw("mutation", one_of(Enum.map([:path, :size, :digest, :field], &constant/1)))

    bad =
      case mutation do
        :path ->
          put_in(fixture(), ["platforms", platform, "path"], "../executor")

        :size ->
          put_in(
            fixture(),
            ["platforms", platform, "bytes"],
            draw("bytes", one_of([integer(-100..0), integer(104_857_601..104_858_000)]))
          )

        :digest ->
          put_in(fixture(), ["platforms", platform, "sha256"], String.duplicate("A", 64))

        :field ->
          update_in(
            fixture(),
            ["platforms", platform],
            &Map.put(&1, "url", "https://foreign.invalid")
          )
      end

    assert {:error, :invalid_executor_bootstrap} = ExecutorBootstrap.decode(bad)
  end
end
