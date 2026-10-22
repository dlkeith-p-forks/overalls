# Issues one view ticket of the kind named by ARTIFACT_TICKET_KIND for the
# seeded probe artifact and writes it privately. Refusal kinds bind the ticket
# to an expired lifetime, a revoked state, a nonexistent version or a user
# without read access; the content endpoint MUST refuse each of them.
{:ok, _} = Application.ensure_all_started(:marshall)

Code.require_file(System.fetch_env!("ARTIFACT_MACHINE_FIXTURE"))
alias ArtifactMachineFixture, as: TestSupport

state = "/run/overalls-test/artifact-origin.json" |> File.read!() |> JSON.decode!()
artifact = %{id: state["artifact_id"], version: state["version"]}
owner = state["owner_id"]
kind = System.fetch_env!("ARTIFACT_TICKET_KIND")

options =
  case kind do
    "valid" -> [user_id: owner]
    "expired" -> [user_id: owner, expires_in: -60]
    "revoked" -> [user_id: owner, revoked: true]
    "wrong_version" -> [user_id: owner, version: state["version"] + 98]
    "other_user" -> [user_id: state["other_id"]]
  end

ticket = TestSupport.issue_ticket!(artifact, options)
true = is_binary(ticket) and Regex.match?(~r/\A[A-Za-z0-9_-]{32,128}\z/, ticket)
path = "/run/overalls-test/artifact-ticket-#{kind}"
File.write!(path, ticket)
File.chmod!(path, 0o600)
