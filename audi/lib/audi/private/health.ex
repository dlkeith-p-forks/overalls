defmodule Audi.Private.Health do
  @moduledoc "Local DNS listener and verified private TLS readiness."
  @spec ready?(Path.t()) :: boolean()
  def ready?(roots) do
    if Audi.DNS.Server.ready?(Audi.Private.DNS.Server) do
      case :ssl.connect(
             {169, 254, 254, 1},
             443,
             [
               verify: :verify_peer,
               cacertfile: String.to_charlist(roots),
               server_name_indication: ~c"llm.internal",
               active: false,
               customize_hostname_check: [
                 match_fun: :public_key.pkix_verify_hostname_match_fun(:https)
               ]
             ],
             1000
           ) do
        {:ok, socket} ->
          :ssl.close(socket)
          true

        _ ->
          false
      end
    else
      false
    end
  end
end
