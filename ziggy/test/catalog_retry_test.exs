defmodule Ziggy.CatalogRetryTest do
  use ExUnit.Case, async: false

  test "a failed discovery retries within seconds instead of the full interval" do
    {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
    {:ok, port} = :inet.port(listener)
    :ok = :gen_tcp.close(listener)

    tasks = start_supervised!({Task.Supervisor, name: :catalog_retry_tasks})

    catalog =
      start_supervised!(
        {Ziggy.Catalog,
         credentials: %{openai: "test-key"},
         openai_origin: "http://127.0.0.1:#{port}",
         tasks: tasks}
      )

    assert eventually(fn -> :sys.get_state(catalog).failures >= 2 end, 8_000)
    refute Ziggy.Catalog.ready?(catalog)
  end

  @spec eventually((-> boolean()), integer()) :: boolean()
  defp eventually(check, remaining) do
    cond do
      check.() -> true
      remaining <= 0 -> false
      true -> Process.sleep(100) && eventually(check, remaining - 100)
    end
  end
end
