defmodule Marshall.Ingress.FleetCertificateProgress do
  @moduledoc "Dispatch certificate progress from the issuer-only Oban queue."
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.before_action(changeset, fn current ->
      :ok = Marshall.Ingress.CertificateAuthority.step(current.data.id)
      current
    end)
  end
end
