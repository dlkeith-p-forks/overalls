defmodule Lilly.Host.TemplateStewardTest do
  use ExUnit.Case, async: true
  import Hegel
  import Hegel.Gen
  alias Lilly.Host.{Image, Pool, TemplateSteward}

  defp pool,
    do: %Pool{
      id: Lilly.UUID.generate(),
      path: "/steward-test/" <> Integer.to_string(System.unique_integer([:positive])),
      filesystem_id: "zfs:1:2"
    }

  defp image(n),
    do: %Image{
      id: "sha256:" <> String.pad_leading(Integer.to_string(n), 64, "0"),
      path: "/nonexistent",
      manifest: %{},
      files: %{}
    }

  # @cc [owner:ghuntley,label:verification;concurrency] template-builds-coalesce
  # Concurrent ensure/4 callers for one pool and image MUST trigger exactly one
  # build and all receive its result; different images build independently; a
  # caller whose wait expires gets storage_busy without stopping the build; a
  # crashed build answers template_unconfirmed.
  property "concurrent callers for one pool and image share one build" do
    check all(callers <- integer(1..12), images <- integer(1..3), max_runs: 15) do
      pool = pool()
      parent = self()

      build = fn _pool, image ->
        send(parent, {:build, image.id})
        Process.sleep(60)
        {:error, :template_unconfirmed}
      end

      results =
        for caller <- 1..callers, image_n <- 1..images do
          Task.async(fn -> TemplateSteward.ensure(pool, image(image_n), 5_000, build) end)
          |> then(&{caller, image_n, &1})
        end
        |> Enum.map(fn {_caller, _image, task} -> Task.await(task, 10_000) end)

      assert Enum.all?(results, &(&1 == {:error, :template_unconfirmed}))

      builds =
        Stream.repeatedly(fn ->
          receive do
            {:build, id} -> id
          after
            100 -> nil
          end
        end)
        |> Enum.take_while(& &1)

      # Every caller arrives while its image's 60 ms build runs: one build each.
      assert Enum.sort(builds) == Enum.sort(Enum.map(1..images, &image(&1).id))
    end
  end

  test "an expired wait does not cancel the build; a crash answers unconfirmed" do
    pool = pool()
    parent = self()

    slow = fn _pool, _image ->
      send(parent, :started)
      Process.sleep(300)
      send(parent, :finished)
      :ok
    end

    assert {:error, :storage_busy} = TemplateSteward.ensure(pool, image(1), 50, slow)
    assert_receive :started, 1000
    assert_receive :finished, 2000

    crash = fn _pool, _image -> exit(:boom) end
    assert {:error, :template_unconfirmed} = TemplateSteward.ensure(pool, image(2), 2000, crash)
  end
end
