defmodule MarshallWeb.HealthTest do
  use MarshallWeb.ConnCase, async: false
  import Hegel
  import Hegel.Gen
  alias Marshall.Operations.Health

  test "live and ready probes have fixed responses and no session cookies", %{conn: conn} do
    for path <- ["/health/live", "/health/ready"] do
      response = get(conn, path)
      assert response.status == 200
      assert response.resp_body == "ok\n"
      assert get_resp_header(response, "cache-control") == ["no-store"]
      assert response.resp_cookies == %{}
    end

    assert head(conn, "/health/ready").resp_body == ""
  end

  test "unapplied release schema is not ready but the process is live", %{conn: conn} do
    Ecto.Adapters.SQL.query!(Marshall.Repo, "DELETE FROM schema_migrations WHERE version = $1", [
      Health.required_version()
    ])

    response = get(conn, "/health/ready")
    assert response.status == 503
    assert response.resp_body == "unavailable\n"
    assert get(conn, "/health/live").status == 200
  end

  test "read-only transactions cannot report ready", %{conn: conn} do
    Ecto.Adapters.SQL.query!(Marshall.Repo, "SET TRANSACTION READ ONLY", [],
      sandbox_subtransaction: false
    )

    assert %{rows: [["on"]]} =
             Ecto.Adapters.SQL.query!(Marshall.Repo, "SHOW transaction_read_only")

    refute Health.ready?()
    assert get(conn, "/health/ready").status == 503
  end

  # @cc [owner:ghuntley,label:verification;recovery] health-inconclusive-property
  # For any observation sequence, readiness MUST follow definite answers at once
  # and keep a ready verdict through unanswered probes only within the backstop.
  @tag :hegel_case_sandbox
  property "unanswered probes keep readiness only within the backstop" do
    Marshall.DataCase.isolate_property_case()

    steps =
      draw(
        "steps",
        list_of(
          tuple({member_of([:ready, :not_ready, :inconclusive]), integer(0..20000)}),
          max_length: 40
        )
      )

    Enum.reduce(steps, {nil, 0}, fn {observation, gap}, {last, now} ->
      now = now + gap
      {verdict, next} = Health.decide(last, observation, now)

      case observation do
        :ready ->
          assert {verdict, next} == {true, now}

        :not_ready ->
          assert {verdict, next} == {false, nil}

        :inconclusive ->
          assert {verdict, next} == {last != nil and now - last < Health.backstop_ms(), last}
      end

      {next, now}
    end)
  end

  test "an unanswered probe keeps a recent ready verdict but never invents one" do
    assert Health.ready?()
    assert unanswered_ready?()

    Ecto.Adapters.SQL.query!(Marshall.Repo, "DELETE FROM schema_migrations WHERE version = $1", [
      Health.required_version()
    ])

    refute Health.ready?()
    refute unanswered_ready?()
  end

  # A bare process has no sandbox allowance, so its probe goes unanswered.
  @spec unanswered_ready?() :: boolean()
  defp unanswered_ready? do
    parent = self()
    spawn(fn -> send(parent, {:unanswered, Health.ready?()}) end)
    assert_receive {:unanswered, verdict}, 5_000
    verdict
  end
end
