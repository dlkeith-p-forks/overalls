# @cc [owner:ghuntley,label:security;verification] artifact-origin-fixture-custody
# Disposable login tokens, artifact identities and view tickets MUST stay in
# private 0600 files under /run/overalls-test and are never printed. Artifact
# rows MUST be created only through the reviewed ArtifactMachineFixture, which
# uses Marshall's authorized actions; the browser performs every view.
{:ok, _} = Application.ensure_all_started(:marshall)

Code.require_file(System.fetch_env!("ARTIFACT_MACHINE_FIXTURE"))
alias ArtifactMachineFixture, as: TestSupport

write_private = fn path, contents ->
  File.write!(path, contents)
  File.chmod!(path, 0o600)
end

Ash.Seed.seed!(Marshall.Accounts.User, %{
  email: "artifact-bootstrap@example.test",
  administrator: true
})

[bootstrap] =
  Marshall.Compute.Ledger.read!(Marshall.Accounts.AdminBootstrap, id: "installation")

Marshall.Compute.Ledger.update!(bootstrap, :complete, %{})

owner = Ash.Seed.seed!(Marshall.Accounts.User, %{email: "artifact-owner@example.test"})
other = Ash.Seed.seed!(Marshall.Accounts.User, %{email: "artifact-other@example.test"})

strategy = AshAuthentication.Info.strategy!(Marshall.Accounts.User, :magic_link)
{:ok, token} = AshAuthentication.Strategy.MagicLink.request_token_for(strategy, owner)
write_private.("/run/overalls-test/artifact-owner-token", token)

fixtures = System.fetch_env!("ARTIFACT_ORIGIN_FIXTURES")

files =
  Map.new(["index.html", "image.svg", "sniff.txt", "payload.exe"], fn name ->
    {name, File.read!(Path.join(fixtures, name))}
  end)

%{id: artifact_id, version: version} =
  TestSupport.seed_artifact!(%{
    owner_id: owner.id,
    title: "Artifact origin probe",
    entry: "index.html",
    files: files
  })

write_private.(
  "/run/overalls-test/artifact-origin.json",
  JSON.encode!(%{
    artifact_id: artifact_id,
    version: version,
    owner_id: owner.id,
    other_id: other.id
  })
)
