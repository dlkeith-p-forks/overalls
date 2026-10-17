defmodule Ziggy.UpdateArtifactTest do
  @moduledoc """
  Closed-denial semantics for the private guest-update artifact routes.

  Servable bytes require Marshall's decision to carry the packaged digest and
  size exactly; authority refusal is the only guest-distinguishable denial
  (403), while package mismatch and authority unavailability are identical
  closed 503s that never reveal the packaged path, digest or size.
  """
  use ExUnit.Case, async: true
  import Plug.Conn

  @host "11111111-1111-4111-8111-111111111111"
  @digest String.duplicate("a", 64)
  @artifact %{path: "/nix/store/synthetic-release/bin/linux-amd64", digest: @digest, size: 1024}

  defp wire_binding(host \\ @host) do
    %{
      "host_id" => host,
      "vm_id" => @host,
      "placement_id" => @host,
      "execution_epoch" => 1
    }
  end

  defp artifact_conn(method_host, path, wire) do
    Plug.Test.conn(:get, "http://#{method_host}#{path}")
    |> put_req_header(
      "x-overalls-binding",
      Base.url_encode64(Jason.encode!(wire), padding: false)
    )
  end

  test "authority unavailability is a closed 503 for both artifact routes" do
    config = %{host_id: @host, control: nil, update_artifact: @artifact}

    for path <- ["/agent/v1/update/manifest.json", "/agent/v1/update/bin/linux-amd64"] do
      response = Ziggy.HTTP.call(artifact_conn("llm.internal", path, wire_binding()), config)
      assert response.status == 503
      assert Jason.decode!(response.resp_body) == %{"error" => "unavailable"}
    end
  end

  test "unconfigured release is the same closed 503", do: unconfigured()

  defp unconfigured do
    config = %{host_id: @host, control: nil}

    response =
      Ziggy.HTTP.call(
        artifact_conn("llm.internal", "/agent/v1/update/manifest.json", wire_binding()),
        config
      )

    assert response.status == 503
    assert Jason.decode!(response.resp_body) == %{"error" => "unavailable"}
  end

  test "foreign bindings are refused before release resolution" do
    config = %{host_id: @host, control: nil, update_artifact: @artifact}

    foreign =
      artifact_conn(
        "llm.internal",
        "/agent/v1/update/manifest.json",
        wire_binding("22222222-2222-4222-8222-222222222222")
      )

    response = Ziggy.HTTP.call(foreign, config)
    assert response.status == 403
    assert Jason.decode!(response.resp_body) == %{"error" => "unauthorized"}
  end

  test "the packaged artifact is servable only on an exact decision match" do
    assert {:ok, path, digest, size} =
             Ziggy.HTTP.artifact_decision(
               {:ok, %{"sha256" => @digest, "bytes" => 1024}},
               @artifact
             )

    assert {path, digest, size} == {@artifact.path, @digest, @artifact.size}
  end

  test "digest and size mismatches deny without revealing packaged material" do
    mismatches = [
      {:ok, %{"sha256" => String.duplicate("b", 64), "bytes" => 1024}},
      {:ok, %{"sha256" => @digest, "bytes" => 1025}},
      {:ok, %{"sha256" => String.upcase(@digest), "bytes" => 1024}},
      {:ok, %{"sha256" => @digest}},
      {:ok, %{"bytes" => 1024}},
      {:ok, %{"sha256" => 7, "bytes" => 1024}},
      {:ok, %{"sha256" => @digest, "bytes" => "1024"}},
      {:ok, %{}},
      {:ok, "not-a-map"},
      {:error, :authority_unavailable},
      {:error, :timeout},
      :garbage,
      nil
    ]

    for decision <- mismatches do
      assert {:error, :unavailable} = Ziggy.HTTP.artifact_decision(decision, @artifact)
    end
  end

  test "authority refusal is the only guest-distinguishable denial" do
    assert {:error, :unauthorized} =
             Ziggy.HTTP.artifact_decision({:error, :unauthorized}, @artifact)
  end
end
