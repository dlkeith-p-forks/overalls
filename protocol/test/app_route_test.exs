defmodule OverallsProtocol.AppRouteTest do
  use ExUnit.Case, async: true
  import Hegel
  import Hegel.Gen
  alias OverallsProtocol.AppRoute

  # Shared with Mila's Dart parser so both sides accept and refuse the same links.
  @vectors Path.expand("fixtures/app_routes.json", __DIR__)
  @external_resource @vectors

  @spec vectors() :: map()
  defp vectors, do: @vectors |> File.read!() |> JSON.decode!()

  test "shared vectors accept, canonicalise and refuse the same links as Mila" do
    %{"version" => 1, "accepted" => accepted, "refused" => refused} = vectors()

    for %{"input" => input, "canonical" => canonical, "route" => expected} <- accepted do
      assert {:ok, route} = AppRoute.parse(input), input
      assert AppRoute.format(route) == canonical, input
      assert AppRoute.describe(route) == expected, input
      assert {:ok, ^route} = AppRoute.parse(canonical), input
    end

    for input <- refused do
      assert {:error, :invalid_route} = AppRoute.parse(input), inspect(input)
    end
  end

  test "non-binary and oversized values are refused" do
    for value <- [nil, 1, :machines, ~c"overalls://h/machines", %{}] do
      assert {:error, :invalid_route} = AppRoute.parse(value)
    end

    long = "overalls://overalls.example/launch?source=" <> String.duplicate("a", 2048)
    assert {:error, :invalid_route} = AppRoute.parse(long)
  end

  property "formatted routes parse back to the same route" do
    route = draw("route", route())
    assert {:ok, ^route} = route |> AppRoute.format() |> AppRoute.parse()
    assert byte_size(AppRoute.format(route)) <= 2048
  end

  property "arbitrary input never raises and refuses or yields a canonical route" do
    input = draw("input", one_of([binary(0, 96), mutated()]))

    case AppRoute.parse(input) do
      {:ok, route} -> assert {:ok, ^route} = route |> AppRoute.format() |> AppRoute.parse()
      {:error, :invalid_route} -> :ok
    end
  end

  property "appending a fragment, query key or segment to a route refuses it" do
    route = draw("route", route())
    suffix = draw("suffix", member_of(["#x", "/extra", "/", "&x=1"]))
    # A launch source is a provider URL, so a path suffix can name another valid repository path.
    if match?({:launch, _}, route.page) and suffix in ["/extra", "/"], do: reject()
    link = AppRoute.format(route)

    link =
      if suffix == "&x=1" and not String.contains?(link, "?"), do: link <> "?x=1", else: link

    assert {:error, :invalid_route} = AppRoute.parse(link <> suffix)
  end

  defp route do
    gen all(
          host <- host(),
          port <- one_of([constant(nil), integer(1, 65_535)]),
          page <- page()
        ) do
      %{host: host, port: port, page: page}
    end
  end

  defp host do
    gen all(labels <- list(label(), min: 1, max: 4)) do
      Enum.join(labels, ".")
    end
  end

  defp label do
    gen all(
          first <- member_of(Enum.to_list(?a..?z) ++ Enum.to_list(?0..?9)),
          rest <- list(member_of(Enum.to_list(?a..?z) ++ Enum.to_list(?0..?9)), max: 10)
        ) do
      List.to_string([first | rest])
    end
  end

  defp uuid do
    gen all(bytes <- binary(16, 16)) do
      <<a::32, b::16, c::16, d::16, e::48>> = bytes

      [<<a::32>>, <<b::16>>, <<c::16>>, <<d::16>>, <<e::48>>]
      |> Enum.map_join("-", &Base.encode16(&1, case: :lower))
    end
  end

  defp page do
    one_of([
      member_of([:machines, :threads, :settings]),
      map(uuid(), &{:machine, &1}),
      map(uuid(), &{:machine_info, &1}),
      map(uuid(), &{:machine_web, &1}),
      map(uuid(), &{:machine_terminals, &1}),
      map(uuid(), &{:machine_threads, &1}),
      map(uuid(), &{:thread, &1}),
      map(uuid(), &{:ssh_approved, &1}),
      map(tuple([uuid(), uuid()]), fn {id, session} -> {:machine_terminal, id, session} end),
      map(tuple([uuid(), uuid()]), fn {id, thread} -> {:machine_thread, id, thread} end),
      map(member_of(sources()), &{:launch, &1})
    ])
  end

  defp sources do
    for url <- [
          "https://github.com/ghuntley/overalls",
          "https://gitlab.com/group/sub/project/-/merge_requests/7",
          "https://codeberg.org/owner/repo/src/branch/main",
          "https://bitbucket.org/team/repo/commits/0123456789abcdef0123456789abcdef01234567"
        ] do
      {:ok, source} = OverallsProtocol.WorkspaceSource.parse_url(url)
      source
    end
  end

  defp mutated do
    gen all(
          route <- route(),
          position <- integer(0, 200),
          byte <- integer(0, 255)
        ) do
      link = AppRoute.format(route)
      at = min(position, byte_size(link))
      binary_part(link, 0, at) <> <<byte>> <> binary_part(link, at, byte_size(link) - at)
    end
  end
end
