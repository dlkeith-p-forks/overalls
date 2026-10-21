defmodule Marshall.Agents.ModelProtocolTest do
  use ExUnit.Case, async: true
  alias Marshall.Agents.{Event, ModelProtocol}

  test "subscription delivery enters model context as a system notification" do
    body = %{
      "kind" => "machine_purged",
      "thread_id" => Ecto.UUID.generate(),
      "notification_id" => Ecto.UUID.generate(),
      "sequence" => 1
    }

    event = struct(Event, %{kind: :subscription_notification, sequence: 1, body: body})
    assert {:ok, request} = ModelProtocol.request([event], "gpt-6-sol", :standard)

    assert Enum.any?(request["input"], fn item ->
             item["role"] == "developer" and is_binary(item["content"]) and
               String.contains?(item["content"], body["notification_id"])
           end)

    refute Enum.any?(request["input"], &(&1["role"] == "user"))
  end

  test "thread replay accepts integer cursors and rejects strings and unrelated fields" do
    response = fn args ->
      %{
        "status" => "completed",
        "output" => [
          %{
            "type" => "function_call",
            "call_id" => "replay",
            "name" => "thread",
            "arguments" => Jason.encode!(args)
          }
        ]
      }
    end

    args = %{"operation" => "replay", "thread_id" => Ecto.UUID.generate(), "cursor" => 1}

    assert {:ok, {:tools, [%{tool: :thread}]}} =
             ModelProtocol.parse_response(response.(args), :standard)

    for invalid <- [
          Map.put(args, "cursor", "1"),
          Map.put(args, "cursor", -1),
          Map.put(args, "active", true)
        ] do
      assert {:error, _} = ModelProtocol.parse_response(response.(invalid), :standard)
    end
  end

  test "board calls reject forged scope and malformed post arguments" do
    response = fn args ->
      %{
        "status" => "completed",
        "output" => [
          %{
            "type" => "function_call",
            "call_id" => "board",
            "name" => "message_board",
            "arguments" => Jason.encode!(args)
          }
        ]
      }
    end

    args = %{"operation" => "post", "body" => "working", "idempotency_key" => "retry"}

    assert {:ok, {:tools, [%{tool: :message_board}]}} =
             ModelProtocol.parse_response(response.(args), :standard)

    for key <- ~w(user_id profile vm_id thread_id root_id) do
      assert {:error, _} =
               ModelProtocol.parse_response(response.(Map.put(args, key, "forged")), :standard)
    end

    assert {:error, _} =
             ModelProtocol.parse_response(response.(%{"operation" => "post"}), :standard)

    assert {:error, :capability_denied} = ModelProtocol.parse_response(response.(args), :customer)

    assert {:error, :capability_denied} =
             ModelProtocol.parse_response(response.(args), :inception)
  end

  test "attachment uploads use guest paths and reject inline bytes" do
    args = %{
      "operation" => "upload",
      "thread_id" => Ecto.UUID.generate(),
      "idempotency_key" => "upload",
      "path" => "/workspace/file.bin"
    }

    response = fn arguments ->
      %{
        "status" => "completed",
        "output" => [
          %{
            "type" => "function_call",
            "call_id" => "upload",
            "name" => "attachment",
            "arguments" => Jason.encode!(arguments)
          }
        ]
      }
    end

    assert {:ok, {:tools, [%{tool: :attachment}]}} =
             ModelProtocol.parse_response(response.(args), :standard)

    assert {:error, _} =
             ModelProtocol.parse_response(
               response.(Map.put(args, "content_base64", "eA==")),
               :standard
             )

    assert {:error, _} =
             ModelProtocol.parse_response(response.(Map.put(args, "path", "relative")), :standard)
  end

  test "ordered private thread events become a bounded model context" do
    events = [
      struct(Event, %{
        kind: :tool_result,
        sequence: 3,
        body: %{"call_id" => "call-1", "result" => %{"stdout" => "ok"}}
      }),
      struct(Event, %{kind: :prompt, sequence: 1, body: %{"prompt" => "inspect"}}),
      struct(Event, %{
        kind: :tool_queued,
        sequence: 2,
        body: %{
          "calls" => [
            %{"call_id" => "call-1", "tool" => "exec_command", "arguments" => %{"cmd" => "pwd"}}
          ]
        }
      })
    ]

    assert {:ok,
            %{
              "input" => messages,
              "stream" => true,
              "store" => false,
              "reasoning" => %{"effort" => "medium"},
              "include" => ["reasoning.encrypted_content"]
            }} = ModelProtocol.request(events, "gpt-6-sol", :standard)

    assert Enum.map(messages, &(&1["role"] || &1["type"])) ==
             ["system", "user", "function_call", "function_call_output"]

    assert List.last(messages)["call_id"] == "call-1"
  end

  test "a Windows guest request names PowerShell and Windows paths; Unix wording is unchanged" do
    events = [struct(Event, %{kind: :prompt, sequence: 1, body: %{"prompt" => "inspect"}})]

    {:ok, unix} = ModelProtocol.request(events, "gpt-6-sol", :standard)
    {:ok, windows} = ModelProtocol.request(events, "gpt-6-sol", :standard, :windows)

    assert ModelProtocol.request(events, "gpt-6-sol", :standard, :unix) == {:ok, unix}
    [%{"content" => unix_system} | _] = unix["input"]
    [%{"content" => windows_system} | _] = windows["input"]
    refute unix_system =~ "PowerShell"
    assert windows_system =~ "Windows PowerShell 5.1"
    assert windows_system =~ "C:\\workspace"
    assert Enum.map(windows["tools"], & &1["name"]) == Enum.map(unix["tools"], & &1["name"])

    exec = Enum.find(windows["tools"], &(&1["name"] == "exec_command"))
    assert exec["description"] =~ "Windows PowerShell 5.1"
    assert exec["parameters"]["properties"]["workdir"]["description"] =~ "Absolute Windows path"

    refute Enum.find(unix["tools"], &(&1["name"] == "exec_command"))["description"] =~
             "PowerShell"
  end

  test "read_file accepts drive-rooted Windows paths as well as Unix paths" do
    for path <- ["C:\\workspace\\README.md", "/workspace/README.md"] do
      response = %{
        "status" => "completed",
        "output" => [
          %{
            "type" => "function_call",
            "call_id" => "call-1",
            "name" => "read_file",
            "arguments" => Jason.encode!(%{"path" => path})
          }
        ]
      }

      assert {:ok, {:tools, [%{tool: :read_file, arguments: %{"path" => ^path}}]}} =
               ModelProtocol.parse_response(response, :standard)
    end

    response = %{
      "status" => "completed",
      "output" => [
        %{
          "type" => "function_call",
          "call_id" => "call-1",
          "name" => "read_file",
          "arguments" => Jason.encode!(%{"path" => "workspace\\README.md"})
        }
      ]
    }

    assert {:error, _} = ModelProtocol.parse_response(response, :standard)
  end

  test "Responses tool calls retain encrypted reasoning in the next bounded request" do
    response = %{
      "status" => "completed",
      "output" => [
        %{"type" => "reasoning", "encrypted_content" => "opaque"},
        %{
          "type" => "function_call",
          "call_id" => "call-1",
          "name" => "read_file",
          "arguments" => ~s({"path":"/etc/hostname"})
        }
      ]
    }

    assert {:ok, {:tools, [%{id: "call-1", tool: :read_file}]}} =
             ModelProtocol.parse_response(response, :standard)

    assert {:ok, output} = ModelProtocol.replay_output(response)

    events = [
      struct(Event, %{kind: :prompt, turn_id: "turn-1", sequence: 1, body: %{"prompt" => "read"}}),
      struct(Event, %{
        kind: :model_output,
        turn_id: "turn-1",
        sequence: 2,
        body: %{"output" => output}
      }),
      struct(Event, %{
        kind: :tool_queued,
        turn_id: "turn-1",
        sequence: 3,
        body: %{
          "calls" => [
            %{
              "call_id" => "call-1",
              "tool" => "read_file",
              "arguments" => %{"path" => "/etc/hostname"}
            }
          ]
        }
      }),
      struct(Event, %{
        kind: :tool_result,
        turn_id: "turn-1",
        sequence: 4,
        body: %{"call_id" => "call-1", "result" => %{"contents" => "host"}}
      })
    ]

    assert {:ok, %{"input" => input}} = ModelProtocol.request(events, "gpt-6-sol", :standard)

    assert Enum.map(input, &(&1["role"] || &1["type"])) ==
             ["system", "user", "reasoning", "function_call", "function_call_output"]

    assert {:error, :invalid_response} =
             ModelProtocol.parse_response(
               %{
                 "status" => "incomplete",
                 "output" => response["output"]
               },
               :standard
             )
  end

  test "tool calls accept only bounded known tools and typed arguments" do
    response = %{
      "choices" => [
        %{
          "message" => %{
            "tool_calls" => [
              %{
                "id" => "call-1",
                "type" => "function",
                "function" => %{"name" => "exec_command", "arguments" => ~s({"cmd":"pwd"})}
              }
            ]
          }
        }
      ]
    }

    assert {:ok, {:tools, [%{id: "call-1", tool: :exec_command}]}} =
             ModelProtocol.parse_response(response, :standard)

    forged =
      put_in(
        response,
        ["choices", Access.at(0), "message", "tool_calls", Access.at(0), "function", "name"],
        "delete_vm"
      )

    assert {:error, :invalid_response} = ModelProtocol.parse_response(forged, :standard)
  end

  test "attachment download accepts its unordered JSON fields" do
    response = %{
      "status" => "completed",
      "output" => [
        %{
          "type" => "function_call",
          "call_id" => "download",
          "name" => "attachment",
          "arguments" =>
            Jason.encode!(%{
              "operation" => "download",
              "attachment_id" => Ecto.UUID.generate(),
              "path" => "/tmp/output"
            })
        }
      ]
    }

    assert {:ok, {:tools, [%{tool: :attachment}]}} =
             ModelProtocol.parse_response(response, :standard)
  end

  test "attachment tool accepts typed path uploads" do
    response = %{
      "status" => "completed",
      "output" => [
        %{
          "type" => "function_call",
          "call_id" => "attachment-1",
          "name" => "attachment",
          "arguments" =>
            Jason.encode!(%{
              "operation" => "upload",
              "thread_id" => Ecto.UUID.generate(),
              "idempotency_key" => "upload-1",
              "path" => "/workspace/hello.txt"
            })
        }
      ]
    }

    assert {:ok, {:tools, [%{tool: :attachment}]}} =
             ModelProtocol.parse_response(response, :standard)
  end

  test "projection preserves all events before compaction evaluates the request" do
    events =
      Enum.map(1..300, fn sequence ->
        struct(Event, %{
          kind: :prompt,
          sequence: sequence,
          body: %{"prompt" => "request #{sequence}"}
        })
      end)

    assert {:ok, projected} =
             ModelProtocol.project(events, "test-model", :standard, :unix, :medium)

    assert length(projected["input"]) == 301
    assert {:error, :context_too_large} = ModelProtocol.request(events, "test-model", :standard)
    assert {:ok, items} = ModelProtocol.context_items(events)
    assert hd(items)["content"] == "request 1"
    assert List.last(items)["content"] == "request 300"
  end

  test "checkpoint data cannot acquire instruction roles and canonical context is restored" do
    events = [struct(Event, %{kind: :prompt, sequence: 30, body: %{"prompt" => "continue"}})]

    assert {:ok, request} =
             ModelProtocol.request(events, "test-model", :standard, :unix, :medium,
               instructions: ["Project instructions."],
               checkpoint: %{"kind" => "summary", "text" => "Earlier outcome."},
               retained_input: [%{"role" => "assistant", "content" => "Retained."}]
             )

    assert Enum.map(request["input"], & &1["role"]) == [
             "system",
             "developer",
             "assistant",
             "assistant",
             "user"
           ]

    assert Enum.at(request["input"], 1)["content"] == "Project instructions."
    assert Enum.at(request["input"], 2)["content"] =~ "Earlier outcome."
    assert List.last(request["input"])["content"] == "continue"
  end

  test "human planning questions are root Plan controls only" do
    events = [struct(Event, %{kind: :prompt, sequence: 1, body: %{"prompt" => "design"}})]
    {:ok, work} = ModelProtocol.request(events, "test-model", :standard)

    {:ok, plan} =
      ModelProtocol.request(events, "test-model", :standard, :unix, :medium,
        collaboration_mode: :plan
      )

    {:ok, child} =
      ModelProtocol.request(events, "test-model", :standard, :unix, :medium,
        collaboration_mode: :plan,
        child?: true
      )

    refute Enum.any?(work["tools"], &(&1["name"] == "request_user_input"))
    assert Enum.any?(plan["tools"], &(&1["name"] == "request_user_input"))
    refute Enum.any?(child["tools"], &(&1["name"] == "request_user_input"))
    assert ModelProtocol.request_tools_allowed?(plan, :standard, collaboration_mode: :plan)
    refute ModelProtocol.request_tools_allowed?(plan, :standard)
    refute ModelProtocol.request_tools_allowed?(plan, :customer, collaboration_mode: :plan)

    arguments = %{
      "questions" => [
        %{
          "id" => "storage",
          "header" => "Storage",
          "question" => "Which persistence?",
          "options" => [
            %{"label" => "Local", "description" => "Keep machine data."},
            %{"label" => "Shared", "description" => "Use shared storage."}
          ]
        }
      ]
    }

    response = %{
      "status" => "completed",
      "output" => [
        %{
          "type" => "function_call",
          "call_id" => "ask-1",
          "name" => "request_user_input",
          "arguments" => Jason.encode!(arguments)
        }
      ]
    }

    assert {:ok, {:tools, [%{tool: :request_user_input}]}} =
             ModelProtocol.parse_response(response, :standard, collaboration_mode: :plan)

    assert {:error, :capability_denied} = ModelProtocol.parse_response(response, :standard)

    assert {:error, :capability_denied} =
             ModelProtocol.parse_response(response, :standard,
               collaboration_mode: :plan,
               child?: true
             )
  end

  test "accepts bounded typed thread operations" do
    response = %{
      "status" => "completed",
      "output" => [
        %{
          "type" => "function_call",
          "call_id" => "thread-1",
          "name" => "thread",
          "arguments" =>
            Jason.encode!(%{"operation" => "search", "query" => "build", "limit" => 10})
        }
      ]
    }

    assert {:ok, {:tools, [%{tool: :thread, arguments: %{"operation" => "search"}}]}} =
             ModelProtocol.parse_response(response, :standard)
  end
end
