defmodule MarshallWeb.AttachmentControllerTest do
  use MarshallWeb.ConnCase, async: false

  test "authenticated download returns bytes once and revoked login cannot consume a token", %{
    conn: conn
  } do
    actor = Marshall.ComputeFixtures.user()

    {:ok, thread} =
      Marshall.Threads.create_thread(
        %{
          objective: "HTTP attachment test",
          mode: :medium,
          machine_spec: %{
            architecture: :x86_64,
            profile: :standard,
            image_id: "sha256:" <> String.duplicate("a", 64),
            vcpu: 2,
            memory_bytes: 4_294_967_296,
            disk_bytes: 42_949_672_960,
            team_id: nil
          },
          idempotency_key: Ecto.UUID.generate()
        },
        actor: actor
      )

    store = Marshall.Agents.AttachmentStore
    previous = Application.get_env(:marshall, store)
    root = Path.join(System.tmp_dir!(), "attachment-http-#{Ecto.UUID.generate()}")

    Application.delete_env(:marshall, store)
    File.mkdir_p!(root)

    on_exit(fn ->
      if previous == nil,
        do: Application.delete_env(:marshall, store),
        else: Application.put_env(:marshall, store, previous)

      File.rm_rf!(root)
    end)

    {:ok, %{id: id}} =
      Marshall.Agents.AttachmentTransfers.upload(actor.id, thread.id, "http", "private bytes")

    {:ok, login_token, _} = AshAuthentication.Jwt.token_for_user(actor)

    signed =
      conn
      |> init_test_session(%{})
      |> AshAuthentication.Plug.Helpers.store_in_session(
        Ash.Resource.put_metadata(actor, :token, login_token)
      )

    source = Path.join(root, "source.bin")
    File.write!(source, "multipart private bytes")

    upload_reply =
      post(signed, "/attachments/threads/#{thread.id}", %{
        "idempotency_key" => "multipart",
        "file" => %Plug.Upload{
          path: source,
          filename: "sample.bin",
          content_type: "application/octet-stream"
        }
      })

    uploaded = json_response(upload_reply, 201)

    row =
      Ash.get!(Marshall.Agents.Attachment, uploaded["id"],
        actor: Marshall.Authorization.SystemActor.compute()
      )

    assert row.storage_key == "chunks:" <> uploaded["id"]
    refute Map.has_key?(uploaded, "content_base64")
    refute upload_reply.resp_body =~ "multipart private bytes"

    {:ok, %{download_token: uploaded_token}} =
      Marshall.Agents.AttachmentTool.download(actor.id, uploaded["id"])

    uploaded_reply =
      signed
      |> put_req_header("x-attachment-token", uploaded_token)
      |> post("/attachments/#{uploaded["id"]}/download")

    assert response(uploaded_reply, 200) == "multipart private bytes"
    {:ok, %{download_token: token}} = Marshall.Agents.AttachmentTool.download(actor.id, id)

    reply =
      signed
      |> put_req_header("x-attachment-token", token)
      |> post("/attachments/#{id}/download")

    assert response(reply, 200) == "private bytes"
    assert get_resp_header(reply, "cache-control") == ["private, no-store"]

    assert get_resp_header(reply, "content-disposition") == [
             "attachment; filename=\"attachment.bin\""
           ]

    replay =
      signed
      |> put_req_header("x-attachment-token", token)
      |> post("/attachments/#{id}/download")

    assert response(replay, 404) == ""
    {:ok, %{download_token: fresh}} = Marshall.Agents.AttachmentTool.download(actor.id, id)

    :ok =
      AshAuthentication.TokenResource.Actions.revoke(
        Marshall.Accounts.Token,
        get_session(signed, "user_token")
      )

    refused =
      signed
      |> put_req_header("x-attachment-token", fresh)
      |> post("/attachments/#{id}/download")

    assert response(refused, 404) == ""

    assert {:ok, "private bytes"} =
             Marshall.Agents.AttachmentTool.resolve_download(actor.id, id, fresh)
  end

  test "anonymous download refuses without returning bytes", %{conn: conn} do
    conn = post(conn, "/attachments/#{Ecto.UUID.generate()}/download")
    assert response(conn, 404) == ""
    assert get_resp_header(conn, "cache-control") == ["private, no-store"]
  end

  test "malformed attachment identifiers fail closed", %{conn: conn} do
    conn = post(conn, "/attachments/not-a-uuid/download")
    assert response(conn, 404) == ""
  end

  test "attachment requests are privacy tagged before downstream diagnostics" do
    previous = Logger.metadata()
    on_exit(fn -> Logger.reset_metadata(previous) end)
    Logger.reset_metadata([])
    conn = Plug.Test.conn(:post, "/attachments/unknown/download")
    assert ^conn = MarshallWeb.AuthenticationPrivacy.call(conn, [])
    assert Logger.metadata()[:marshall_authentication] == true
  end
end
