defmodule Audi.SSH.Backend do
  @moduledoc "Trusted authority/connector boundary; the default denies every request."
  @type grant :: %{binding: map(), ticket: term(), ttl: pos_integer()}
  @callback key_status(term(), OverallsProtocol.SSHKey.t()) ::
              {:ok, OverallsProtocol.SSHOnboarding.key_status()} | {:error, atom()}
  @callback authorize(term(), OverallsProtocol.SSHKey.t(), Audi.SSH.Request.selector()) ::
              {:ok, grant()} | {:error, atom()}
  @callback connect(term(), term(), map()) :: {:ok, :gen_tcp.socket()} | {:error, atom()}
  @callback renew(term(), term(), map()) ::
              {:ok, %{binding: map(), ttl: pos_integer()}} | {:error, atom()}

  # @cc [owner:ghuntley,label:security] audi-key-recognition-is-not-admission
  # Key recognition MUST require a proved key and trusted Marshall response.
  # Neither recognized nor unknown status may grant access or cache authority.
  @spec key_status(term(), term()) :: {:error, :unavailable}
  def key_status(_, _), do: {:error, :unavailable}

  # @cc [owner:ghuntley,label:security] audi-ssh-backend-authority
  # Implementations MUST use current Marshall placement authority and a
  # restricted local Lilly connector. A ticket MUST NOT select arbitrary IPs or
  # ports. connect MUST return a passive raw socket owned by the caller. Admission
  # and renewal MUST fail closed; callbacks MUST NOT log inputs or trap exits.
  # Ordinary VM SSH MUST require Marshall user authority. Nested SSH MUST bind
  # the selected environment/service and published host key after signature
  # proof; inner user authentication remains the inner service's responsibility.
  # The default implementation MUST grant no access.
  @spec authorize(term(), term(), term()) :: {:error, :unavailable}
  def authorize(_, _, _), do: {:error, :unavailable}
  @spec connect(term(), term(), term()) :: {:error, :unavailable}
  def connect(_, _, _), do: {:error, :unavailable}
  @spec renew(term(), term(), term()) :: {:error, :unavailable}
  def renew(_, _, _), do: {:error, :unavailable}
end
