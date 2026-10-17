defmodule Marshall.Ingress.ACME.Issuer do
  @moduledoc "Individual ACME operations; durable scheduling and custody belong to the coordinator."
  alias Marshall.Ingress.ACME.{AccountKey, JWS, Resources, Transport}
  alias Marshall.Ingress.ACME.{Material, Request}
  @derive {Inspect, only: []}
  @enforce_keys [:client, :key, :routes, :kid]
  defstruct [:client, :key, :routes, :kid]
  @type t :: %__MODULE__{client: Transport.t(), key: AccountKey.t(), routes: map(), kid: binary()}

  # @cc [owner:ghuntley,label:security;protocol] acme-account-terms
  # Account registration MUST require explicit caller acceptance of issuer terms
  # and a valid issuer account response and Location. No operation may infer
  # acceptance from a network response or silently create an account on retry.
  @spec register(Transport.t(), AccountKey.t(), boolean()) :: {:ok, t()} | {:error, term()}
  def register(client, key, true) do
    with {:ok, routes} <- Transport.directory(client),
         {:ok, %{status: status, location: kid, body: body}} when status in [200, 201] <-
           Transport.post(client, key, routes["newNonce"], routes["newAccount"], :new_account, %{
             termsOfServiceAgreed: true
           }),
         true <- Resources.url?(client, kid),
         {:ok, %{"status" => "valid"}} <- decode(body) do
      {:ok, %__MODULE__{client: client, key: key, routes: routes, kid: kid}}
    else
      {:error, _} = error -> error
      _ -> {:error, :invalid_acme_resource}
    end
  end

  def register(_, _, _), do: {:error, :terms_not_accepted}

  # @cc [owner:ghuntley,label:security;recovery] acme-existing-account-recovery
  # Recovery MUST request onlyReturnExisting with the saved key, accept only a
  # valid existing account and same-origin Location, and MUST NOT create an
  # account, accept new terms or fall back to registration after failure.
  @spec recover(Transport.t(), AccountKey.t()) :: {:ok, t()} | {:error, term()}
  def recover(client, key) do
    with {:ok, routes} <- Transport.directory(client),
         {:ok, %{status: 200, location: kid, body: body}} <-
           Transport.post(client, key, routes["newNonce"], routes["newAccount"], :new_account, %{
             onlyReturnExisting: true
           }),
         true <- Resources.url?(client, kid),
         {:ok, %{"status" => "valid"}} <- decode(body) do
      {:ok, %__MODULE__{client: client, key: key, routes: routes, kid: kid}}
    else
      {:error, _} = error -> error
      _ -> {:error, :invalid_acme_resource}
    end
  end

  @spec create_order(t(), Request.t()) :: {:ok, map()} | {:error, term()}
  def create_order(issuer, %Request{hostname: host}) do
    payload = %{identifiers: [%{type: "dns", value: "*." <> host}]}

    with {:ok, %{status: 201, location: url, body: body}} <-
           post(issuer, issuer.routes["newOrder"], payload),
         true <- Resources.url?(issuer.client, url),
         {:ok, value} <- decode(body),
         {:ok, order} <- Resources.order(issuer.client, value, host) do
      {:ok, Map.put(order, :url, url)}
    else
      {:error, _} = error -> error
      _ -> {:error, :invalid_acme_resource}
    end
  end

  @spec poll_order(t(), map()) :: {:ok, map()} | {:error, term()}
  def poll_order(issuer, order), do: order_response(issuer, order, order.url, :post_as_get)

  @spec authorization(t(), binary(), binary(), boolean() | :any) ::
          {:ok, map()} | {:error, term()}
  def authorization(issuer, url, host, wildcard \\ :any) do
    with {:ok, %{status: 200, body: body}} <- post(issuer, url, :post_as_get),
         {:ok, value} when is_map(value) <- decode(body),
         {:ok, authorization} <-
           Resources.authorization(
             issuer.client,
             value,
             host,
             if(wildcard == :any, do: Map.get(value, "wildcard", false), else: wildcard)
           ),
         {:ok, proof} <- JWS.dns_proof(issuer.key, authorization.challenge.token) do
      {:ok, Map.merge(authorization, %{url: url, proof: proof})}
    else
      {:error, _} = error -> error
      _ -> {:error, :invalid_acme_resource}
    end
  end

  @spec acknowledge(t(), map()) :: {:ok, map()} | {:error, term()}
  def acknowledge(issuer, authorization) do
    with {:ok, %{status: 200, body: body}} <- post(issuer, authorization.challenge.url, %{}),
         {:ok, %{"type" => "dns-01", "url" => url, "token" => token, "status" => status}} <-
           decode(body),
         true <- url == authorization.challenge.url and token == authorization.challenge.token,
         true <- status in ["pending", "processing", "valid", "invalid"] do
      {:ok, %{status: status}}
    else
      {:error, _} = error -> error
      _ -> {:error, :invalid_acme_resource}
    end
  end

  # @cc [owner:ghuntley,label:security] acme-finalization-material
  # Finalization MUST bind a ready order to the matching fleet wildcard request. Download
  # MUST require a valid order and validate the returned certificate chain, names
  # and key before returning material. Neither operation installs or publishes it.
  @spec finalize(t(), map(), Request.t()) :: {:ok, map()} | {:error, term()}
  def finalize(
        issuer,
        %{status: "ready", hostname: host} = order,
        %Request{hostname: host} = request
      ),
      do:
        order_response(issuer, order, order.finalize, %{
          csr: Base.url_encode64(request.der, padding: false)
        })

  def finalize(_, _, _), do: {:error, :invalid_acme_resource}

  @spec download(t(), map(), Request.t(), binary()) :: {:ok, Material.t()} | {:error, term()}
  def download(
        issuer,
        %{status: "valid", hostname: host} = order,
        %Request{hostname: host} = request,
        roots
      ) do
    with {:ok, %{status: 200, body: chain}} <- post(issuer, order.certificate, :post_as_get) do
      Material.validate(chain, request.private_key_pem, roots, host)
    else
      {:error, _} = error -> error
      _ -> {:error, :invalid_acme_resource}
    end
  end

  def download(_, _, _, _), do: {:error, :invalid_acme_resource}

  defp order_response(issuer, order, url, payload) do
    with {:ok, %{status: 200, body: body}} <- post(issuer, url, payload),
         {:ok, value} <- decode(body),
         {:ok, updated} <- Resources.order(issuer.client, value, order.hostname),
         true <-
           Enum.sort(updated.authorizations) == Enum.sort(order.authorizations) and
             updated.finalize == order.finalize do
      {:ok, Map.put(updated, :url, order.url)}
    else
      {:error, _} = error -> error
      _ -> {:error, :invalid_acme_resource}
    end
  end

  defp decode(body) do
    case Jason.decode(body) do
      {:ok, value} when is_map(value) -> {:ok, value}
      _ -> {:error, :invalid_acme_resource}
    end
  end

  defp post(issuer, url, payload),
    do:
      Transport.post(
        issuer.client,
        issuer.key,
        issuer.routes["newNonce"],
        url,
        {:account, issuer.kid},
        payload
      )
end
