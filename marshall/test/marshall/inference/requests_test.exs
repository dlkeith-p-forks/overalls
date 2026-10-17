defmodule Marshall.Inference.RequestsTest do
  use Marshall.DataCase, async: false
  import Hegel
  import Hegel.Gen
  alias Marshall.Compute.{Ledger, VirtualMachine}
  alias Marshall.Inference.{Credentials, Requests, Request}

  setup context do
    fixture =
      Marshall.TerminalFixtures.terminal_fixture(%{
        profile: Map.get(context, :profile, :standard)
      })

    {:ok, key} = Credentials.rotate(fixture.vm.host_id, 3600)
    token = key.id <> "." <> key.secret

    input = %{
      "request_id" => Ash.UUID.generate(),
      "host_id" => fixture.vm.host_id,
      "vm_id" => fixture.vm.id,
      "placement_id" => fixture.vm.current_placement_id,
      "execution_epoch" => fixture.vm.execution_epoch,
      "provider" => "openai",
      "model" => "provider-new-model",
      "operation" => "responses"
    }

    Map.merge(fixture, %{ziggy_token: token, input: input})
  end

  @tag profile: :customer
  test "Customer cannot authorize, admit or renew inference", c do
    binding = Map.take(c.input, ~w(host_id vm_id placement_id execution_epoch))
    assert {:error, _} = Requests.authorize(c.ziggy_token, binding)
    assert {:error, _} = Requests.admit(c.ziggy_token, c.input)
    assert [] = Ledger.read!(Request, vm_id: c.vm.id)
    {:ok, input} = OverallsProtocol.Inference.admission(c.input)
    [credential_id, _] = String.split(c.ziggy_token, ".")

    old =
      Ledger.create!(
        Request,
        :record,
        Map.merge(input, %{
          owner_id: c.owner.id,
          generation: c.vm.generation,
          credential_id: credential_id,
          expires_at: DateTime.add(Ledger.now(), 30, :second)
        })
      )

    [before] = Ledger.read!(Request, id: old.id)
    assert {:error, _} = Requests.renew(c.ziggy_token, old.id)
    assert [^before] = Ledger.read!(Request, vm_id: c.vm.id)
  end

  test "admission persists owner before execution and duplicate IDs cannot replay", c do
    assert {:ok, grant} = Requests.admit(c.ziggy_token, c.input)
    assert grant.owner_id == c.owner.id
    assert grant.ttl_ms == 30_000
    assert {:error, _} = Requests.admit(c.ziggy_token, c.input)
    [row] = Ledger.read!(Request, id: grant.request_id)
    assert row.completion == nil
    assert {:ok, _} = Requests.renew(c.ziggy_token, grant.request_id)
    assert {:ok, _} = Requests.complete(c.ziggy_token, grant.request_id, completion())
    assert {:ok, _} = Requests.complete(c.ziggy_token, grant.request_id, completion())

    assert {:error, _} =
             Requests.complete(
               c.ziggy_token,
               grant.request_id,
               Map.put(completion(), "outcome", "cancelled")
             )

    assert {:error, _} = Requests.renew(c.ziggy_token, grant.request_id)
    [daily] = Ledger.read!(Marshall.Inference.Daily, owner_id: c.owner.id)
    assert daily.requests == 1
    assert daily.unknown_requests == 1
    assert {:ok, page} = Marshall.Inference.list_usage(%{}, actor: c.owner)
    assert length(page.rows) == 1
    assert page.totals.requests == 1
    assert length(page.chart) == 30
    stranger = Marshall.ComputeFixtures.user()
    assert {:ok, %{rows: []}} = Marshall.Inference.list_usage(%{}, actor: stranger)
    assert {:ok, %{rows: [_]}} = Marshall.Inference.list_usage_for_admin(%{}, actor: stranger)
  end

  test "the database refuses a completion outside the exact wire shape", c do
    assert {:ok, grant} = Requests.admit(c.ziggy_token, c.input)
    [row] = Ledger.read!(Request, id: grant.request_id)

    for legacy <- [
          Map.merge(completion(), %{"duration_ms" => 42, "http_status" => 200}),
          Map.delete(completion(), "tokens")
        ] do
      assert_raise Ash.Error.Invalid, fn ->
        Ledger.update!(row, :complete, %{completion: legacy, completed_at: Ledger.now()})
      end
    end

    id = grant.request_id
    assert [%{completion: nil}] = Ledger.read!(Request, id: id)
    assert {:ok, %{acknowledged: ^id}} = Requests.complete(c.ziggy_token, id, completion())
    assert {:ok, %{acknowledged: ^id}} = Requests.complete(c.ziggy_token, id, completion())
  end

  property "completion replay and conflict histories count each request once", c do
    check all(
            attempts <- list_of(member_of([:replay, :conflict]), min_length: 1, max_length: 12),
            max_runs: 12
          ) do
      id = Ash.UUID.generate()
      input = Map.put(c.input, "request_id", id)

      previous =
        Ledger.read!(Marshall.Inference.Daily, owner_id: c.owner.id)
        |> Enum.reduce(0, fn daily, total -> total + daily.requests end)

      assert {:ok, %{request_id: ^id}} = Requests.admit(c.ziggy_token, input)
      assert {:ok, %{acknowledged: ^id}} = Requests.complete(c.ziggy_token, id, completion())
      [committed] = Ledger.read!(Request, id: id)

      for attempt <- attempts do
        result =
          case attempt do
            :replay ->
              Requests.complete(c.ziggy_token, id, completion())

            :conflict ->
              Requests.complete(
                c.ziggy_token,
                id,
                Map.put(completion(), "outcome", "cancelled")
              )
          end

        assert result ==
                 if(attempt == :replay,
                   do: {:ok, %{acknowledged: id}},
                   else: {:error, :completion_conflict}
                 )

        assert Ledger.read!(Request, id: id) == [committed]

        daily_rows = Ledger.read!(Marshall.Inference.Daily, owner_id: c.owner.id)
        assert Enum.sum(Enum.map(daily_rows, & &1.requests)) == previous + 1
        assert Enum.sum(Enum.map(daily_rows, & &1.unknown_requests)) == previous + 1
      end
    end
  end

  test "retired owners cannot admit or renew inference but accounting can finish", c do
    {:ok, grant} = Requests.admit(c.ziggy_token, c.input)
    Ledger.update!(c.owner, :security_state, %{deleted_at: Ledger.now()})
    assert {:error, _} = Requests.renew(c.ziggy_token, grant.request_id)

    assert {:error, _} =
             Requests.admit(c.ziggy_token, Map.put(c.input, "request_id", Ash.UUID.generate()))

    assert {:error, _} =
             Requests.authorize(
               c.ziggy_token,
               Map.take(c.input, ~w(host_id vm_id placement_id execution_epoch))
             )

    assert {:ok, _} = Requests.complete(c.ziggy_token, grant.request_id, completion())
  end

  test "epoch change and credential rotation fence renewal", c do
    {:ok, grant} = Requests.admit(c.ziggy_token, c.input)
    [vm] = Ledger.read!(VirtualMachine, id: c.vm.id)

    Ledger.intent!(vm, %{
      generation: vm.generation + 1,
      desired_state: :stopped
    })

    assert {:error, _} = Requests.renew(c.ziggy_token, grant.request_id)
    assert {:ok, _} = Requests.complete(c.ziggy_token, grant.request_id, completion())
    {:ok, _} = Credentials.rotate(c.vm.host_id, 3600)

    assert {:error, _} =
             Requests.authorize(
               c.ziggy_token,
               Map.take(c.input, ~w(host_id vm_id placement_id execution_epoch))
             )
  end

  test "claimed owner, content fields and another host never authorize", c do
    assert {:error, _} = Requests.admit(c.ziggy_token, Map.put(c.input, "owner_id", c.owner.id))
    assert {:error, _} = Requests.admit(c.ziggy_token, Map.put(c.input, "prompt", "synthetic"))

    assert {:error, _} =
             Requests.admit(c.ziggy_token, Map.put(c.input, "host_id", Ash.UUID.generate()))

    assert {:error, _} =
             Requests.admit(
               c.ziggy_token,
               Map.put(c.input, "execution_epoch", c.vm.execution_epoch + 1)
             )

    assert {:error, _} = Requests.admit(c.credential.token, c.input)
  end

  @tag :tmp_dir
  test "operator rotation keeps tokens in private files and refuses overwrite", c do
    File.chmod!(c.tmp_dir, 0o700)
    output = Path.join(c.tmp_dir, "ziggy.token")

    assert {:ok, %{credential_id: id}} =
             Marshall.Operations.Inference.rotate(c.vm.host_id, 3600, output)

    assert {:ok, %{credential_id: ^id, verified: true}} =
             Marshall.Operations.Inference.verify(output)

    assert {:error, _} = Marshall.Operations.Inference.rotate(c.vm.host_id, 3600, output)
    assert {:ok, %{credential_id: ^id}} = Marshall.Operations.Inference.verify(output)
    assert {:error, _} = Credentials.authenticate(c.ziggy_token)
    assert {:ok, %{revoked: true}} = Marshall.Operations.Inference.revoke(c.vm.host_id)
    assert {:error, _} = Marshall.Operations.Inference.verify(output)
    assert Bitwise.band(File.stat!(output).mode, 0o777) == 0o600
  end

  defp completion,
    do: %{
      "outcome" => "interrupted",
      "tokens" => %{},
      "completeness" => "unknown"
    }
end
