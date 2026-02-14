defmodule BeamClaw.Gateway.ChatControllerTest do
  use ExUnit.Case
  import Plug.Test
  import Plug.Conn

  @opts BeamClaw.Gateway.Router.init([])

  test "POST /v1/chat/completions with missing messages returns 400" do
    conn =
      conn(:post, "/v1/chat/completions", Jason.encode!(%{model: "test"}))
      |> put_req_header("content-type", "application/json")
      |> put_req_header("accept", "application/json")
      |> BeamClaw.Gateway.Router.call(@opts)

    assert conn.status == 400
    body = Jason.decode!(conn.resp_body)
    assert body["error"]["message"] =~ "messages"
  end

  test "POST /v1/chat/completions with empty messages returns 400" do
    conn =
      conn(:post, "/v1/chat/completions", Jason.encode!(%{messages: []}))
      |> put_req_header("content-type", "application/json")
      |> put_req_header("accept", "application/json")
      |> BeamClaw.Gateway.Router.call(@opts)

    assert conn.status == 400
  end
end
