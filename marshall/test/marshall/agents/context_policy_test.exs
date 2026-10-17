defmodule Marshall.Agents.ContextPolicyTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Marshall.Agents.ContextPolicy

  test "omitted limits stay unknown and native compaction is disabled" do
    assert ContextPolicy.from_env(%{}) ==
             {:ok, %{input_token_limit: nil, native_compaction_verified: false}}
  end

  test "native support requires an exact explicit capability assertion" do
    assert {:ok, %{native_compaction_verified: true}} =
             ContextPolicy.from_env(%{"MARSHALL_AGENT_NATIVE_COMPACTION_VERIFIED" => "true"})

    for value <- ["", "TRUE", "yes", "1", " true", "false "] do
      assert {:error, :invalid_native_compaction_capability} =
               ContextPolicy.from_env(%{"MARSHALL_AGENT_NATIVE_COMPACTION_VERIFIED" => value})
    end
  end

  test "invalid input allowances fail instead of silently changing the trigger" do
    for value <- ["", "0", "-1", " 10", "10 ", "1.5", "100tokens", "2147483648"] do
      assert {:error, :invalid_context_input_limit} =
               ContextPolicy.from_env(%{"MARSHALL_AGENT_CONTEXT_INPUT_TOKEN_LIMIT" => value})
    end
  end

  property "configured positive allowances preserve their exact value" do
    check all(limit <- integer(1..2_147_483_647)) do
      assert {:ok, %{input_token_limit: ^limit, native_compaction_verified: false}} =
               ContextPolicy.from_env(%{
                 "MARSHALL_AGENT_CONTEXT_INPUT_TOKEN_LIMIT" => Integer.to_string(limit)
               })
    end
  end
end
