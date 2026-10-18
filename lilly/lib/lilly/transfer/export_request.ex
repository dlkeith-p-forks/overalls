defmodule Lilly.Transfer.ExportRequest do
  @moduledoc "Closed SSH export requests bound to durable local permits."
  alias Lilly.Transfer.PermitJournal

  @type request :: %{
          required(:relocation_id) => String.t(),
          optional(:resume_token) => String.t(),
          optional(:component) => :checkpoint
        }
  @type failure :: {:error, :export_permit_unconfirmed}

  # @cc [owner:ghuntley,label:security] export-request-is-never-shell-text
  # parse/1 MUST accept only the exact fixed v4 verb and canonical relocation
  # UUID separated by a single space; there is one full disk stream and, only
  # with a RAM-bearing permit, one distinct lilly-checkpoint-v1 command. It MUST reject shell syntax,
  # extra arguments and alternate whitespace without normalization or evaluation.
  # The distinct resume verb permits exactly one bounded hexadecimal token envelope;
  # this syntax check grants no lineage or transfer authority.
  @spec parse(term()) :: {:ok, request()} | failure()
  def parse("lilly-export-v4 " <> <<relocation::binary-size(36)>>) do
    if OverallsProtocol.uuid?(relocation),
      do: {:ok, %{relocation_id: relocation}},
      else: failure()
  end

  def parse("lilly-resume-v4 " <> <<relocation::binary-size(36), " ", token::binary>>) do
    with {:ok, request} <- parse("lilly-export-v4 " <> relocation),
         true <- token?(token),
         do: {:ok, Map.put(request, :resume_token, token)},
         else: (_ -> failure())
  end

  def parse("lilly-checkpoint-v1 " <> <<relocation::binary-size(36)>>) do
    if OverallsProtocol.uuid?(relocation),
      do: {:ok, %{relocation_id: relocation, component: :checkpoint}},
      else: failure()
  end

  def parse(_), do: failure()

  # @cc [owner:ghuntley,label:security] authorized-key-forces-server-selected-identity
  # authorized_key/5 is a read-only AuthorizedKeysCommand lookup, not proof of
  # private-key possession. It MUST return only an unexpired local key binding
  # with an active export or probe grant, restrict and a forced command containing
  # that exact key. The
  # executable is a trusted root-owned installation path, never peer input; reject
  # shell expansion/quoting syntax in it. OpenSSH must verify possession before
  # executing this command, and the export endpoint must recheck the live permit.
  @spec authorized_key(Path.t(), String.t(), String.t(), Path.t(), integer()) ::
          {:ok, String.t()} | failure()
  def authorized_key(root, host, public, executable, now) do
    with true <- is_binary(executable),
         true <- Regex.match?(~r/\A\/[a-zA-Z0-9_.\/-]+\z/, executable),
         true <- Path.expand(executable) == executable,
         {:ok, _} <- PermitJournal.authentication(root, host, public, now),
         "ssh-ed25519 " <> encoded <- public do
      {:ok, "restrict,command=\"#{executable} #{encoded}\" #{public}\n"}
    else
      _ -> failure()
    end
  end

  # @cc [owner:ghuntley,label:security;recovery] export-request-does-not-authenticate-its-own-peer
  # lookup/5 requires root/host from trusted local configuration and public from
  # the server-authenticated SSH identity, never from client command/environment
  # fields. It MUST resolve the relocation's full-stream grant through the durable permit.
  # Success is a read-only snapshot, not launch authority: callers MUST serialize
  # launch registration against revocation, recheck native ownership and supervise
  # process expiry/quiescence as required by PermitJournal.lookup/5.
  @spec lookup(Path.t(), String.t(), String.t(), term(), integer()) ::
          {:ok, map()} | failure()
  def lookup(root, host, public, command, now) do
    with {:ok, request} <- parse(command),
         {:ok, grant} <- PermitJournal.lookup(root, host, request.relocation_id, public, now),
         true <-
           Map.get(request, :component) != :checkpoint or
             Map.has_key?(grant.descriptor, :checkpoint),
         do: {:ok, grant},
         else: (_ -> failure())
  end

  @doc "Bounded shell-inert token syntax only; native source lineage validation is mandatory."
  @spec token?(term()) :: boolean()
  def token?(token) when is_binary(token) and byte_size(token) in 1..8192,
    do: Regex.match?(~r/\A1-[0-9a-f]{1,16}-[0-9a-f]{1,16}-(?:[0-9a-f]{2})+\z/, token)

  def token?(_), do: false

  defp failure, do: {:error, :export_permit_unconfirmed}
end
