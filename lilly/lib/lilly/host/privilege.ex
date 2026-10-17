defmodule Lilly.Host.Privilege do
  @moduledoc """
  The service identity Lilly's ownership checks trust (ADR-0182).

  Lilly state is written either by lilly-hostd (as root) or by the BEAM
  itself (as the configured service user). `lstat/2` and `stat/1` report a
  file owned by the configured service uid as uid 0, so ownership patterns
  that require `uid: 0` accept exactly "root or the service user", and the
  root gates (`stat("/proc/self")` with uid 0) admit exactly a BEAM running
  as root or as that user. The service uid comes from `LILLY_SERVICE_UID`;
  without it it is 0 and nothing changes.

  System files whose root ownership matters on its own (`/etc`, the Nix
  store, configured images) keep plain `File.lstat/1`.
  """

  @key {__MODULE__, :service_uid}

  # @cc [owner:ghuntley,label:security] service-uid-normalised-to-root
  # lstat/2 and stat/1 MUST return File's result unchanged except that a uid
  # equal to the configured service uid (LILLY_SERVICE_UID, default 0) is
  # reported as 0. No other uid, in particular no guest (jail) uid or the
  # uid of an unconfigured non-root BEAM, may be reported as 0, so the root
  # gates still fail closed for any other user.
  @spec lstat(Path.t(), keyword()) :: {:ok, File.Stat.t()} | {:error, File.posix()}
  def lstat(path, options \\ []), do: path |> File.lstat(options) |> normalise()

  @spec stat(Path.t()) :: {:ok, File.Stat.t()} | {:error, File.posix()}
  def stat(path), do: path |> File.stat() |> normalise()

  @doc "The configured service uid (LILLY_SERVICE_UID), read once; 0 when unset."
  @spec service_uid() :: non_neg_integer()
  def service_uid do
    case :persistent_term.get(@key, nil) do
      nil ->
        uid =
          case Integer.parse(System.get_env("LILLY_SERVICE_UID", "0")) do
            {value, ""} when value >= 0 -> value
            _ -> 0
          end

        :persistent_term.put(@key, uid)
        uid

      uid ->
        uid
    end
  end

  @doc "Whether Lilly runs as a configured non-root service user (ADR-0182)."
  @spec unprivileged?() :: boolean()
  def unprivileged?, do: service_uid() != 0

  defp normalise({:ok, %File.Stat{uid: uid} = stat}) do
    if uid != 0 and uid == service_uid(), do: {:ok, %{stat | uid: 0}}, else: {:ok, stat}
  end

  defp normalise(error), do: error
end
