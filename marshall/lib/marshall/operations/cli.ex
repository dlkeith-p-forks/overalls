defmodule Marshall.Operations.CLI do
  @moduledoc "Release entry point: paths and public IDs in arguments; secrets stay in private files."
  alias Marshall.Compute.Enrollment
  alias Marshall.Compute.Drains

  @spec main() :: no_return()
  def main do
    Application.put_env(:marshall, :operator_mode, true)

    case Application.ensure_all_started(:marshall) do
      {:ok, _} ->
        case run(System.argv()) do
          {:ok, metadata} ->
            IO.puts(JSON.encode!(metadata))
            Logger.flush()
            System.halt(0)

          {:error, reason} ->
            IO.puts(:stderr, "Operator command failed: #{reason}")
            Logger.flush()
            System.halt(1)
        end

      _ ->
        IO.puts(:stderr, "Operator application startup failed")
        System.halt(1)
    end
  end

  @spec run([String.t()]) :: {:ok, map()} | {:error, atom()}
  def run(["ziggy-rotate", host, ttl, output]) do
    case Integer.parse(ttl) do
      {seconds, ""} -> Marshall.Operations.Inference.rotate(host, seconds, output)
      _ -> {:error, :invalid_arguments}
    end
  end

  def run(["ziggy-verify", path]), do: Marshall.Operations.Inference.verify(path)
  def run(["ziggy-revoke", host]), do: Marshall.Operations.Inference.revoke(host)

  def run(["galileo-rotate", host, ttl, output]) do
    case Integer.parse(ttl) do
      {seconds, ""} -> Marshall.Operations.Galileo.rotate(host, seconds, output)
      _ -> {:error, :invalid_arguments}
    end
  end

  def run(["galileo-verify", path]), do: Marshall.Operations.Galileo.verify(path)
  def run(["galileo-revoke", host]), do: Marshall.Operations.Galileo.revoke(host)

  def run(["audi-dns-rotate", name, output]),
    do: Marshall.Operations.Audi.rotate_dns(name, output)

  def run(["audi-dns-verify", path]), do: Marshall.Operations.Audi.verify(path)
  def run(["audi-dns-revoke", name]), do: Marshall.Operations.Audi.revoke(name)

  def run(["audi-gateway-rotate", name, host, addresses, output]),
    do: Marshall.Operations.Audi.rotate_gateway(name, host, addresses, output)

  def run(["audi-gateway-verify", path]), do: Marshall.Operations.Audi.verify(path)
  def run(["audi-gateway-revoke", name]), do: Marshall.Operations.Audi.revoke(name)

  def run(["gateway-prepare", output]), do: Marshall.Operations.SSHGateway.prepare(output)

  def run(["gateway-configure", name, credential]),
    do: Marshall.Operations.SSHGateway.configure(name, credential)

  def run(["gateway-disable", id]), do: Marshall.Operations.SSHGateway.disable(id)

  def run(["prepare-enrollment", operation, request, output]),
    do: Marshall.Compute.EnrollmentPreparation.prepare_file(operation, :prepare, request, output)

  def run(["rotate-credential", operation, request, output]),
    do: Marshall.Compute.EnrollmentPreparation.prepare_file(operation, :rotate, request, output)

  def run(["enroll", request, output]), do: Enrollment.enroll_file(request, output)
  def run(["verify", path]), do: Enrollment.verify_file(path)
  def run(["show", name]), do: Enrollment.describe(name)
  def run(["revoke", host]), do: Enrollment.revoke(host)
  def run(["enable", host]), do: Enrollment.set_enabled(host, true)
  def run(["disable", host]), do: Enrollment.set_enabled(host, false)
  def run(["drain", host, request, operator]), do: Drains.request(host, request, operator)
  def run(["drain-status", request]), do: Drains.status(request)
  def run(["resume-host", request]), do: Drains.resume(request)
  def run(["retire-host", request]), do: Drains.retire(request)

  def run(["rotate", host, ttl, output]) do
    case Integer.parse(ttl) do
      {seconds, ""} -> Enrollment.rotate_file(host, seconds, output)
      _ -> {:error, :invalid_arguments}
    end
  end

  def run(_), do: {:error, :invalid_arguments}
end
