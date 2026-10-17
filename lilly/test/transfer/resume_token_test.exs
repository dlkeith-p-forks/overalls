defmodule Lilly.Transfer.ResumeTokenTest do
  use ExUnit.Case, async: true
  alias Lilly.Transfer.ResumeToken

  test "native envelope rejects oversized decompression, malformed encodings and versions privately" do
    helper = System.find_executable("lilly-resume-token") || raise("missing resume-token helper")

    for token <- [
          "",
          "-",
          "2-1-10-aabb",
          "1-1-0-aabb",
          "1-1-4001-aabb",
          "1-1-ffffffffffffffff-aabb",
          "1-1-100-abc",
          "1-1-100-GG",
          "1-1-100-aa\n",
          "1-1-100-" <> String.duplicate("a", 8192)
        ] do
      assert {"", status} =
               System.cmd(helper, ["tank/vm@lilly-b", "123", token], stderr_to_stdout: true)

      assert status != 0
    end
  end

  test "source validation rejects non-GUID bindings and overlong or nonbinary tokens" do
    for {stream, token} <- [
          {%{to_guid: "0"}, "1-1-100-aabb"},
          {%{to_guid: "01"}, "1-1-100-aabb"},
          {%{to_guid: "123"}, String.duplicate("a", 8193)},
          {%{to_guid: "123"}, nil}
        ] do
      assert {:error, :resume_token_unconfirmed} =
               ResumeToken.validate("tank/vm@lilly-b", stream, token)
    end
  end
end
