# Runtime-only synthetic mail; never print tokens, message bodies or exceptions.
defmodule SMTPProbe do
  alias Marshall.Accounts.{AuthEmail, AuthEmails, User}
  alias Marshall.Compute.Ledger
  @root "/run/overalls-smtp-fixture"

  def run do
    oban = Application.fetch_env!(:marshall, Oban)

    Application.put_env(
      :marshall,
      Oban,
      Keyword.put(oban, :testing, :manual)
    )

    {:ok, _} = Application.ensure_all_started(:marshall)
    action = File.read!(Path.join(@root, "action")) |> String.trim()

    if action == "enqueue" do
      strategy = AshAuthentication.Info.strategy!(User, :magic_link)
      email = "smtp-#{Ash.UUID.generate()}@example.test"

      {:ok, token} =
        AshAuthentication.Strategy.MagicLink.request_token_for_identity(strategy, email)

      :ok = AuthEmails.enqueue(email, token)
      [record] = Ledger.read!(AuthEmail, status: :pending)
      File.write!(Path.join(@root, "record"), record.id)
      File.write!(Path.join(@root, "token"), token)
    end

    id = File.read!(Path.join(@root, "record"))

    if action in ["deliver", "fail"] do
      [record] = Ledger.read!(AuthEmail, id: id)
      AshOban.run_trigger(record, :deliver)
      Oban.drain_queue(queue: :mail, with_scheduled: true)
      [result] = Ledger.read!(AuthEmail, id: id)
      expected = if action == "deliver", do: :delivered, else: :pending
      true = result.status == expected
      true = result.encrypted_payload == nil == (expected == :delivered)
    end

    :ok
  end
end

try do
  :ok = SMTPProbe.run()
rescue
  _ ->
    IO.puts(:stderr, "SMTP probe failed")
    System.halt(1)
catch
  _, _ ->
    IO.puts(:stderr, "SMTP probe failed")
    System.halt(1)
end
