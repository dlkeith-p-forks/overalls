defmodule Marshall.Agents.WebSearchDiagnosticsTest do
  use Marshall.DataCase, async: false
  import ExUnit.CaptureLog

  alias Marshall.Agents.WebSearch

  setup do
    previous = Application.fetch_env(:marshall, :serper_key_file)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:marshall, :serper_key_file, value)
        :error -> Application.delete_env(:marshall, :serper_key_file)
      end
    end)
  end

  test "a rejected completion is correlated without disclosing the query" do
    Application.delete_env(:marshall, :serper_key_file)
    work = work()

    logs =
      capture_log([metadata: [:event, :command_id, :claim_id, :reason]], fn ->
        assert :ok = WebSearch.run(work)
      end)

    assert logs =~ "event=agent.search_execution_failed"
    assert logs =~ "command_id=#{work.id}"
    assert logs =~ "claim_id=#{work.claim_id}"
    assert logs =~ "reason=rejected"
    refute logs =~ work.query
  end

  test "an exception retains the failure class but not its value or query" do
    Application.put_env(:marshall, :serper_key_file, :invalid_path_fixture)
    work = work()

    logs =
      capture_log([metadata: [:event, :command_id, :claim_id, :reason]], fn ->
        assert :ok = WebSearch.run(work)
      end)

    assert logs =~ "event=agent.search_execution_failed"
    assert logs =~ "command_id=#{work.id}"
    assert logs =~ "reason=exception"
    refute logs =~ "invalid_path_fixture"
    refute logs =~ work.query
  end

  @spec work() :: WebSearch.work()
  defp work do
    %{id: Ash.UUID.generate(), claim_id: Ash.UUID.generate(), query: "private-search-fixture"}
  end
end
