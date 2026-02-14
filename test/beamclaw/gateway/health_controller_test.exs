defmodule BeamClaw.Gateway.HealthControllerTest do
  use ExUnit.Case
  import Plug.Test
  import Plug.Conn

  @opts BeamClaw.Gateway.Router.init([])

  test "GET /health returns 200 with status ok" do
    conn =
      conn(:get, "/health")
      |> put_req_header("accept", "application/json")
      |> BeamClaw.Gateway.Router.call(@opts)

    assert conn.status == 200
    body = Jason.decode!(conn.resp_body)
    assert body["status"] == "ok"
    assert is_integer(body["sessions"])
    assert Map.has_key?(body, "uptime_seconds")
  end
end
