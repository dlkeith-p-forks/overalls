defmodule Marshall.Agents.ContextPolicyTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Marshall.Agents.ContextPolicy

  @digest String.duplicate("a", 64)

  test "omitted limits stay unknown and native compaction is disabled" do
    assert ContextPolicy.from_env(%{}) ==
             {:ok, %{input_token_limit: nil, native_compaction_capabilities: []}}
  end

  test "the legacy global switch cannot enable native compaction" do
    assert ContextPolicy.from_env(%{"MARSHALL_AGENT_NATIVE_COMPACTION_VERIFIED" => "true"}) ==
             {:error, :native_compaction_requires_model_allowlist}

    assert {:ok, %{native_compaction_capabilities: []}} =
             ContextPolicy.from_env(%{"MARSHALL_AGENT_NATIVE_COMPACTION_VERIFIED" => "false"})
  end

  test "native support requires exact provider/model evidence entries" do
    encoded =
      Jason.encode!([
        %{"provider" => "openai", "model" => "gpt-6-sol", "evidence_digest" => @digest}
      ])

    assert {:ok, policy} =
             ContextPolicy.from_env(%{"MARSHALL_AGENT_NATIVE_COMPACTION_CAPABILITIES" => encoded})

    assert ContextPolicy.native_compaction_verified?(policy, :openai, "gpt-6-sol")
    refute ContextPolicy.native_compaction_verified?(policy, :openai, "other-model")
    refute ContextPolicy.native_compaction_verified?(policy, :anthropic, "gpt-6-sol")

    for entry <- [
          %{"provider" => "anthropic", "model" => "gpt-6-sol", "evidence_digest" => @digest},
          %{"provider" => "openai", "model" => "gpt-6-sol", "evidence_digest" => "short"},
          %{"provider" => "openai", "model" => "gpt 6", "evidence_digest" => @digest},
          %{
            "provider" => "openai",
            "model" => "gpt-6-sol",
            "evidence_digest" => String.duplicate("A", 64)
          },
          %{
            "provider" => "openai",
            "model" => "gpt-6-sol",
            "evidence_digest" => @digest,
            "extra" => true
          }
        ] do
      assert {:error, :invalid_native_compaction_capability} =
               ContextPolicy.from_env(%{
                 "MARSHALL_AGENT_NATIVE_COMPACTION_CAPABILITIES" => Jason.encode!([entry])
               })
    end
  end

  test "duplicate provider/model evidence entries are rejected" do
    entry = %{"provider" => "openai", "model" => "gpt-6-sol", "evidence_digest" => @digest}

    assert {:error, :invalid_native_compaction_capability} =
             ContextPolicy.from_env(%{
               "MARSHALL_AGENT_NATIVE_COMPACTION_CAPABILITIES" => Jason.encode!([entry, entry])
             })
  end

  test "invalid input allowances fail instead of silently changing the trigger" do
    for value <- ["", "0", "-1", " 10", "10 ", "1.5", "100tokens", "2147483648"] do
      assert {:error, :invalid_context_input_limit} =
               ContextPolicy.from_env(%{"MARSHALL_AGENT_CONTEXT_INPUT_TOKEN_LIMIT" => value})
    end
  end

  property "configured positive allowances preserve their exact value" do
    check all(limit <- integer(1..2_147_483_647)) do
      assert {:ok, %{input_token_limit: ^limit, native_compaction_capabilities: []}} =
               ContextPolicy.from_env(%{
                 "MARSHALL_AGENT_CONTEXT_INPUT_TOKEN_LIMIT" => Integer.to_string(limit)
               })
    end
  end
end
