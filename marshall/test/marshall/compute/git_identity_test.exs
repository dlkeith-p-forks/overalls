defmodule Marshall.Compute.GitIdentityTest do
  use Marshall.DataCase, async: false
  require Hegel
  import Hegel.Gen
  import Marshall.ComputeFixtures
  alias Marshall.Accounts.User
  alias Marshall.Compute.{Ledger, Operation, VirtualMachine}

  # @cc [owner:ghuntley,label:verification;security] git-identity-refusal-case-isolation
  # Every generated case MUST own a fresh SQL sandbox. An image-capability
  # refusal MUST execute all allocation, reservation, dispatch and job assertions;
  # a nested transaction rollback MUST NOT bypass those assertions.
  @tag :hegel
  @tag :hegel_case_sandbox
  test "unsupported images refuse without allocations, reservations or dispatch" do
    Hegel.check(
      fn test_case ->
        Marshall.DataCase.isolate_property_case()

        kind =
          :hegel.draw(test_case, "unsupported image kind", member_of([:linux, :windows, :native]))

        host_fixture()
        actor = user()

        manifest =
          case kind do
            :linux -> Map.delete(image_manifest(), "git_identity_version")
            :windows -> Map.delete(windows_v1_image_manifest(), "git_identity_version")
            :native -> OverallsProtocol.NativeAdmission.reviewed_manifest()
          end

        assert {:ok, image} = Marshall.Compute.Images.register(manifest, "unsupported")
        jobs = Marshall.Repo.aggregate(Oban.Job, :count)

        assert {:error, error} =
                 Marshall.Compute.provision(request(%{image_id: image.id}),
                   actor: actor
                 )

        assert Exception.message(error) =~ "git_identity_unavailable"
        assert Ledger.read!(VirtualMachine) == []
        assert Ledger.read!(Marshall.Compute.WorkloadPlacement) == []
        assert Ledger.read!(Marshall.Compute.Reservation) == []
        assert Ledger.read!(Marshall.Compute.NetworkAddress) == []
        assert Ledger.read!(Operation) == []
        assert Marshall.Repo.aggregate(Oban.Job, :count) == jobs
      end,
      database: :disabled,
      print_blob: false,
      test_cases: 20,
      seed: 814_029_312
    )
  end

  # @cc [owner:ghuntley,label:verification] git-identity-retention-case-isolation
  # Every generated preference/retry history MUST own a fresh SQL sandbox and
  # verify both immutable retained identity and newly allocated identity before
  # cleanup. Replays MUST NOT observe prior generated fixtures.
  @tag :hegel
  @tag :hegel_case_sandbox
  test "allocation retains its snapshot through preference changes and idempotent retry" do
    Hegel.check(
      fn test_case ->
        Marshall.DataCase.isolate_property_case()
        :hegel.note(test_case, "identity suffix = <redacted>")
        suffix = :hegel.draw_silent(test_case, integer(1..100_000))

        host_fixture()
        actor = user()
        name = "Author #{suffix}"
        email = "author#{suffix}@example.test"
        actor = Ash.Seed.update!(actor, %{git_username: name, git_email: email})
        params = request()
        assert {:ok, vm} = Marshall.Compute.provision(params, actor: actor)
        expected = %{"version" => 1, "name" => name, "email" => email}
        assert vm.git_identity == expected

        actor =
          Ash.Seed.update!(actor, %{
            git_username: "Later",
            git_email: "later@example.test"
          })

        assert {:ok, retried} = Marshall.Compute.provision(params, actor: actor)
        assert retried.id == vm.id
        assert retried.git_identity == expected
        [operation] = Ledger.read!(Operation, vm_id: vm.id)
        assert operation.command_snapshot["git_identity"] == expected
        assert {:ok, newer} = Marshall.Compute.provision(request(), actor: actor)
        assert newer.git_identity["name"] == "Later"
        assert [retained] = Ledger.read!(VirtualMachine, id: vm.id)
        assert retained.git_identity == expected
        assert Ash.get!(User, actor.id, authorize?: false).git_username == "Later"
      end,
      database: :disabled,
      print_blob: false,
      test_cases: 20,
      seed: 20_261_020
    )
  end
end
