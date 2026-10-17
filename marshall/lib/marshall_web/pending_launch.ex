defmodule MarshallWeb.PendingLaunch do
  @moduledoc "Bounded signed-session launch input; it grants no provisioning authority."
  alias OverallsProtocol.WorkspaceSource

  @key "pending_repository_launch"
  @lifetime 1_800
  @source_limit 1_024
  @visit ~r/\A[0-9a-f]{32}\z/
  @receipt_salt "repository-launch-completion"

  @type pending :: %{source: String.t(), visit: String.t(), expires_at: integer()}
  @type launch :: %{source: WorkspaceSource.t(), visit: String.t(), expires_at: integer()}
  @type completion :: %{
          user_id: String.t(),
          vm_id: String.t(),
          source: String.t(),
          visit: String.t()
        }

  @spec key() :: String.t()
  def key, do: @key

  # @cc [owner:ghuntley,label:security;product] pending-launch-input-only
  # new/3 MUST accept only a bounded canonical public source and a 128-bit visit
  # nonce, issue a server-time thirty-minute expiry, and create no domain records.
  # A pending record MUST NOT establish identity, passkey proof or VM authority.
  @spec new(term(), term(), integer()) :: {:ok, pending()} | {:error, atom()}
  def new(url, visit, now \\ System.system_time(:second)) do
    with true <- valid_visit?(visit) || {:error, :invalid_visit},
         {:ok, source} <- WorkspaceSource.parse_url(url),
         canonical = WorkspaceSource.to_url(source),
         true <- byte_size(canonical) <= @source_limit || {:error, :invalid_url} do
      {:ok, %{source: canonical, visit: visit, expires_at: now + @lifetime}}
    end
  end

  # @cc [owner:ghuntley,label:security] pending-launch-expiry-and-grammar
  # read/2 MUST revalidate the exact record shape, canonical source, nonce and
  # server-issued expiry on every consumption; malformed or expired records
  # MUST yield no launch. Session data MUST never be treated as domain authority.
  @spec read(map(), integer()) :: launch() | nil
  def read(session, now \\ System.system_time(:second)) do
    validate(Map.get(session, @key), now)
  end

  @spec validate(term(), integer()) :: launch() | nil
  def validate(record, now \\ System.system_time(:second))

  def validate(%{source: url, visit: visit, expires_at: expiry} = record, now)
      when map_size(record) == 3 and is_binary(url) and byte_size(url) <= @source_limit and
             is_integer(expiry) and expiry > now and expiry <= now + @lifetime do
    with true <- valid_visit?(visit),
         {:ok, source} <- WorkspaceSource.parse_url(url),
         ^url <- WorkspaceSource.to_url(source) do
      %{source: source, visit: visit, expires_at: expiry}
    else
      _ -> nil
    end
  end

  def validate(_, _), do: nil

  @spec valid_visit?(term()) :: boolean()
  def valid_visit?(visit),
    do: is_binary(visit) and byte_size(visit) == 32 and Regex.match?(@visit, visit)

  @spec idempotency_key(String.t(), WorkspaceSource.t(), String.t()) :: String.t()
  def idempotency_key(user_id, source, visit) do
    digest =
      :crypto.hash(:sha256, user_id <> "|" <> WorkspaceSource.to_url(source) <> "|" <> visit)

    "launch:" <> Base.encode16(digest, case: :lower)
  end

  # @cc [owner:ghuntley,label:security] completion-receipt-follows-admission
  # receipt/4 MUST be called only after successful authorized Compute.provision.
  # It MUST bind the resulting VM, actor, canonical source and visit; it MUST NOT
  # grant authentication or permission to read a machine.
  @spec receipt(String.t(), String.t(), WorkspaceSource.t(), String.t()) :: String.t()
  def receipt(user_id, vm_id, source, visit) do
    Phoenix.Token.sign(MarshallWeb.Endpoint, @receipt_salt, %{
      user_id: user_id,
      vm_id: vm_id,
      source: WorkspaceSource.to_url(source),
      visit: visit
    })
  end

  @spec verify_receipt(term()) :: {:ok, completion()} | :error
  def verify_receipt(token) when is_binary(token) and byte_size(token) <= 4_096 do
    with {:ok, %{user_id: user, vm_id: vm, source: source, visit: visit} = value} <-
           Phoenix.Token.verify(MarshallWeb.Endpoint, @receipt_salt, token, max_age: @lifetime),
         true <-
           map_size(value) == 4 and OverallsProtocol.uuid?(user) and OverallsProtocol.uuid?(vm),
         {:ok, %{source: ^source}} <- new(source, visit) do
      {:ok, value}
    else
      _ -> :error
    end
  end

  def verify_receipt(_), do: :error

  @spec matches?(map(), completion()) :: boolean()
  def matches?(session, completion) do
    case Map.get(session, @key) do
      %{source: source, visit: visit} ->
        source == completion.source and visit == completion.visit

      _ ->
        false
    end
  end
end
