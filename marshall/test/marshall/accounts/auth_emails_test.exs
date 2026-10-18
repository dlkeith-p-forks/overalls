defmodule Marshall.Accounts.AuthEmailsTest do
  use Marshall.DataCase, async: false
  import Hegel
  import Hegel.Gen
  import ExUnit.CaptureLog
  alias Marshall.Accounts.{AuthEmail, AuthEmails, User}
  alias Marshall.Compute.Ledger

  # @cc [owner:ghuntley,label:verification] uncertain-mail-retry-identity
  # An accepted attempt with an unobserved result MUST leave the row pending;
  # retries MUST retain the delivery's Message-ID and body, and a committed
  # delivered row MUST cause no further mail attempt.
  @tag :hegel_case_sandbox
  property "generated uncertain mail results retain identity and stop after commit",
    test_cases: 100 do
    Marshall.DataCase.isolate_property_case()
    uncertain_attempts = draw("uncertain_attempts", integer(1..3))
    original_config = Application.fetch_env!(:marshall, Marshall.Mailer)

    counter =
      Overalls.HegelFixtures.start_supervised!({Agent, fn -> 0 end}, id: Ash.UUID.generate())

    Application.put_env(
      :marshall,
      Marshall.Mailer,
      adapter: Marshall.Test.UncertainMailAdapter,
      owner: self(),
      counter: counter,
      uncertain_attempts: uncertain_attempts
    )

    try do
      email = "uncertain-#{Ash.UUID.generate()}@example.test"
      assert :ok = AuthEmails.enqueue(email, token(email))
      record = Enum.find(Ledger.read!(AuthEmail), &(&1.status == :pending))
      assert record

      attempts =
        Enum.map(1..(uncertain_attempts + 1), fn attempt ->
          result =
            record
            |> Ash.Changeset.for_update(:deliver, %{},
              actor: Marshall.Authorization.SystemActor.compute()
            )
            |> Ash.update()

          if attempt <= uncertain_attempts do
            assert {:error, _} = result

            assert %{status: :pending} =
                     Ash.get!(AuthEmail, record.id,
                       actor: Marshall.Authorization.SystemActor.compute()
                     )
          else
            assert {:ok, %{status: :delivered}} = result
          end

          assert_receive {:auth_mail_attempt, ^attempt, message_id, text_digest, html_digest}
          {message_id, text_digest, html_digest}
        end)

      assert length(Enum.uniq(attempts)) == 1
      [{message_id, _, _} | _] = attempts
      assert message_id == "<#{record.id}@overalls.invalid>"

      assert %{status: :delivered, encrypted_payload: nil} =
               Ash.get!(AuthEmail, record.id, actor: Marshall.Authorization.SystemActor.compute())

      assert {:ok, %{status: :delivered}} =
               record
               |> Ash.Changeset.for_update(:deliver, %{},
                 actor: Marshall.Authorization.SystemActor.compute()
               )
               |> Ash.update()

      refute_receive {:auth_mail_attempt, _, _, _, _}
      assert Agent.get(counter, & &1) == uncertain_attempts + 1
    after
      Application.put_env(:marshall, Marshall.Mailer, original_config)
    end
  end

  test "real authentication request atomically queues an encrypted email and a private job" do
    email = "mail-#{binary_part(Ash.UUID.generate(), 0, 16)}@example.test"

    assert :ok =
             User
             |> Ash.ActionInput.for_action(:request_magic_link, %{email: email},
               context: %{private: %{ash_authentication?: true}}
             )
             |> Ash.run_action()

    [record] = Ledger.read!(AuthEmail)
    private? = not String.contains?(inspect(record), email)
    assert private?
    assert %Ash.NotLoaded{} = record.payload

    %{rows: [[stored, args]]} =
      Ecto.Adapters.SQL.query!(Repo, """
      SELECT e.encrypted_payload, j.args FROM account_auth_emails e, oban_jobs j
      WHERE j.worker = 'Marshall.Accounts.Workers.DeliverAuthEmail'
      """)

    assert is_binary(stored)
    assert args["primary_key"] == %{"id" => record.id}
    private? = not String.contains?(inspect(args), email)
    assert private?

    old_level = Logger.level()
    Logger.configure(level: :info)
    on_exit(fn -> Logger.configure(level: old_level) end)

    logs =
      capture_log(
        [metadata: [:event, :delivery_id, :delivery_status]],
        fn ->
          assert %{success: 1, failure: 0} = Oban.drain_queue(queue: :mail)
        end
      )

    assert_receive {:email, message}
    assert message.from == {"Overalls", "noreply@example.test"}
    assert message.to == [{"", email}]
    assert String.contains?(message.text_body, "/magic_link/")
    assert [%{status: :delivered, encrypted_payload: nil}] = Ledger.read!(AuthEmail)
    assert %{"purpose" => "magic_link"} = purpose_from_email(message)

    assert logs =~ "Mail attempt finished"
    assert logs =~ "delivery_id=" <> record.id
    assert logs =~ "delivery_status=smtp_accepted"
    refute logs =~ email
    refute String.contains?(logs, Regex.run(~r{/magic_link/([^\s]+)}, message.text_body) |> hd())

    AshOban.run_trigger(record, :deliver)
    assert %{cancelled: 1, failure: 0} = Oban.drain_queue(queue: :mail)
    refute_receive {:email, _}
  end

  test "retries and case-insensitive recipient cooldown do not create extra mail jobs" do
    email = "cooldown-#{Ash.UUID.generate()}@example.test"
    token = token(email)
    assert :ok = AuthEmails.enqueue(email, token)
    assert :ok = AuthEmails.enqueue(email, token)
    upper = String.upcase(email)
    assert :ok = AuthEmails.enqueue(upper, token(upper))
    assert [_] = Ledger.read!(AuthEmail)

    assert %{rows: [[1]]} =
             Ecto.Adapters.SQL.query!(
               Repo,
               "SELECT count(*) FROM oban_jobs WHERE worker = 'Marshall.Accounts.Workers.DeliverAuthEmail'"
             )
  end

  test "consumed or expired links are not sent and leave no retained ciphertext" do
    email = "revoked-#{Ash.UUID.generate()}@example.test"
    token = token(email)
    assert :ok = AuthEmails.enqueue(email, token)
    {:ok, claims} = AshAuthentication.Jwt.peek(token)
    Ecto.Adapters.SQL.query!(Repo, "DELETE FROM tokens WHERE jti = $1", [claims["jti"]])
    assert %{success: 1, failure: 0} = Oban.drain_queue(queue: :mail)
    refute_receive {:email, _}
    assert [%{status: :expired, encrypted_payload: nil}] = Ledger.read!(AuthEmail)

    Ecto.Adapters.SQL.query!(
      Repo,
      "UPDATE account_auth_emails SET expires_at = (clock_timestamp() AT TIME ZONE 'UTC') - interval '1 second'"
    )

    AshOban.schedule(AuthEmail, :purge)
    assert %{success: 2, failure: 0} = Oban.drain_queue(queue: :mail, with_recursion: true)
    assert [] == Ledger.read!(AuthEmail)
  end

  test "ordinary users cannot read, enqueue or deliver authentication mail" do
    actor = Marshall.ComputeFixtures.user()
    assert {:error, %Ash.Error.Forbidden{}} = Ash.read(AuthEmail, actor: actor)

    assert {:error, %Ash.Error.Forbidden{}} =
             AuthEmail
             |> Ash.Changeset.for_create(
               :enqueue,
               %{
                 token_fingerprint: String.duplicate("a", 64),
                 recipient_fingerprint: String.duplicate("b", 64),
                 expires_at: DateTime.add(Ledger.now(), 60),
                 payload: %{"email" => "untrusted@example.test"}
               },
               actor: actor
             )
             |> Ash.create()

    assert :ok = AuthEmails.enqueue(to_string(actor.email), token(to_string(actor.email)))
    [record] = Ledger.read!(AuthEmail)

    assert {:error, %Ash.Error.Forbidden{}} =
             record |> Ash.Changeset.for_update(:deliver, %{}, actor: actor) |> Ash.update()
  end

  defp token(email) do
    strategy = AshAuthentication.Info.strategy!(User, :magic_link)

    {:ok, token} =
      AshAuthentication.Strategy.MagicLink.request_token_for_identity(strategy, email)

    token
  end

  defp purpose_from_email(message) do
    [_, token] = Regex.run(~r{/magic_link/([^\s]+)}, message.text_body)
    {:ok, %{"jti" => jti}} = AshAuthentication.Jwt.peek(token)

    {:ok, [stored]} =
      AshAuthentication.TokenResource.Actions.get_token(
        Marshall.Accounts.Token,
        %{"jti" => jti, "purpose" => "magic_link"}
      )

    %{"purpose" => stored.purpose}
  end
end
