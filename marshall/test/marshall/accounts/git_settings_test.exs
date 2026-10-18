defmodule Marshall.Accounts.GitSettingsTest do
  use Marshall.DataCase, async: false
  import Marshall.ComputeFixtures
  require Hegel
  import Hegel.Gen
  alias Marshall.Accounts.{GitSettings, GitUsername, User}

  @spec update_settings(User.t(), map(), User.t()) :: {:ok, User.t()} | {:error, term()}
  defp update_settings(user, params, actor),
    do: user |> Ash.Changeset.for_update(:git_settings, params) |> Ash.update(actor: actor)

  test "defaults are independent from sign-in identity and foreign writes are refused" do
    owner = user()
    other = user()
    assert owner.git_username == "Overalls"
    assert to_string(owner.git_email) == "noreply@overalls.dev"
    assert owner.commit_trailers_enabled
    assert GitSettings.instruction(Ash.UUID.generate()) =~ "Do not add"
    assert {:error, _} = update_settings(owner, %{git_username: "Foreign"}, other)
    assert {:error, _} = update_settings(owner, %{git_username: "Anonymous"}, nil)
    assert {:error, _} = update_settings(owner, %{git_username: "Bad\nName"}, owner)
    assert {:error, _} = update_settings(owner, %{git_email: "bad\n@example.org"}, owner)
  end

  @tag :hegel
  test "current owner preference supersedes earlier policy without changing fixed attribution" do
    Hegel.check(
      fn test_case ->
        :hegel.note(test_case, "preference history = <redacted>")
        flags = :hegel.draw_silent(test_case, list_of(boolean(), min_length: 1, max_length: 10))

        assert {:error, :case_complete} =
                 Marshall.Repo.transaction(fn ->
                   owner = user()
                   other = user()

                   Enum.reduce(flags, owner, fn enabled, record ->
                     assert {:ok, changed} =
                              update_settings(
                                record,
                                %{
                                  git_username: "Independent Identity",
                                  git_email: "identity@example.org",
                                  commit_trailers_enabled: enabled
                                },
                                owner
                              )

                     instruction = GitSettings.instruction(owner.id)
                     assert byte_size(instruction) < 1024
                     assert instruction =~ "supersedes all earlier"
                     assert instruction =~ "Never amend or rewrite past commits"
                     refute instruction =~ "identity@example.org"

                     if enabled do
                       assert instruction =~ "Co-authored-by: Overalls <noreply@overalls.dev>"
                       assert instruction =~ "append exactly once, after a blank line"
                     else
                       assert instruction =~ "Do not add"
                     end

                     assert GitSettings.instruction(other.id) =~ "Co-authored-by: Overalls"
                     changed
                   end)

                   Marshall.Repo.rollback(:case_complete)
                 end)
      end,
      database: :disabled,
      print_blob: false,
      test_cases: 20,
      seed: 20_261_018
    )
  end

  @tag :hegel
  test "control characters and identity delimiters never form valid Git names" do
    Hegel.check(
      fn test_case ->
        :hegel.note(test_case, "name components = <redacted>")
        prefix = :hegel.draw_silent(test_case, string(:alphanumeric, max_length: 16))

        bad =
          :hegel.draw_silent(test_case, member_of(["\n", "\r", "\0", "\t", "<", ">", <<127>>]))

        suffix = :hegel.draw_silent(test_case, string(:alphanumeric, max_length: 16))
        refute GitUsername.valid?(prefix <> bad <> suffix)
      end,
      database: :disabled,
      print_blob: false,
      test_cases: 50,
      seed: 20_261_019
    )
  end
end
