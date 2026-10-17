defmodule Lilly.Transfer.Permit do
  @moduledoc "Source permit issuance joined to existing native snapshot ownership."
  require Lilly.Events
  alias Lilly.Host.{Lock, Pool}
  alias Lilly.Transfer.{PermitJournal, SourceSnapshots}

  # @cc [owner:ghuntley,label:security] source-permit-rechecks-physical-ownership
  # issue/6 requires the pool lock, authenticated current relocation authority,
  # reserved capacity and a peer key delivered through authenticated control.
  # Initial final-snapshot creation requires the retained launch fence and physical stop;
  # clone renewal may export that same immutable GUID after the independent source restarts.
  # advancement requires prior streams/launchers quiescent. Every grant and renewal
  # MUST revalidate the descriptor against native source ownership before persisting
  # the lease. A durable grant does not prove SSH installation or authorize launch
  # without registration serialized with revocation and runtime lease enforcement.
  @spec issue(Path.t(), Pool.t(), map(), String.t(), pos_integer(), integer()) ::
          :ok | {:error, :export_permit_unconfirmed}
  def issue(root, pool, wire, public, revision, expires) do
    with port when is_struct(port, Lilly.Host.Lease) <- Lock.current(),
         {:ok, _command} <- SourceSnapshots.export(pool, wire),
         :ok <-
           PermitJournal.grant(root, wire, public, revision, expires, System.system_time(:second)),
         do: :ok,
         else: (_ ->
                  Lilly.Events.emit("lilly.transfer_export_failed",
                    reason: :export_permit_unconfirmed
                  )

                  {:error, :export_permit_unconfirmed})
  end
end
