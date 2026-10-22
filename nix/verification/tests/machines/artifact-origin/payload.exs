# Seeds one Hegel-generated escape payload as a fresh artifact owned by the
# probe owner and issues a valid owner ticket for it. The payload bytes come
# from the driver through a private file and are never printed.
{:ok, _} = Application.ensure_all_started(:marshall)

Code.require_file(System.fetch_env!("ARTIFACT_MACHINE_FIXTURE"))
alias ArtifactMachineFixture, as: TestSupport

state = "/run/overalls-test/artifact-origin.json" |> File.read!() |> JSON.decode!()
payload = "/run/overalls-test/artifact-payload.json" |> File.read!() |> JSON.decode!()

files =
  case payload["kind"] do
    "html" ->
      %{"index.html" => payload["body"]}

    "svg" ->
      %{
        "index.html" => "<!doctype html><title>svg host</title><img src=\"payload.svg\" alt=\"\">",
        "payload.svg" => payload["body"]
      }
  end

%{id: artifact_id, version: version} =
  TestSupport.seed_artifact!(%{
    owner_id: state["owner_id"],
    title: "Escape payload",
    entry: "index.html",
    files: files
  })

ticket =
  TestSupport.issue_ticket!(%{id: artifact_id, version: version}, user_id: state["owner_id"])

File.write!("/run/overalls-test/artifact-payload-ticket", ticket)
File.chmod!("/run/overalls-test/artifact-payload-ticket", 0o600)
