defmodule Marshall.AppRoutesTest do
  use ExUnit.Case, async: true
  alias Marshall.AppRoutes
  alias OverallsProtocol.AppRoute

  @id "123e4567-e89b-42d3-a456-426614174000"

  test "links name this deployment's public host and parse back to the same page" do
    %URI{host: host} = URI.parse(MarshallWeb.Endpoint.url())

    for page <- [:machines, :threads, {:machine, @id}, {:thread, @id}, {:ssh_approved, @id}] do
      link = AppRoutes.link(page)
      assert {:ok, %{host: ^host, page: ^page}} = AppRoute.parse(link)
    end
  end

  test "links never carry secrets or query keys beyond the route table" do
    link = AppRoutes.link({:machine, @id})
    refute String.contains?(link, ["?", "#", "@"])
  end
end
