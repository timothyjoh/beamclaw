defmodule BeamClaw.Gateway.RouterTest do
  use ExUnit.Case
  import Plug.Test
  import Plug.Conn

  @opts BeamClaw.Gateway.Router.init([])

  test "GET / returns 200 (LiveView dashboard)" do
    conn =
      conn(:get, "/")
      |> put_req_header("accept", "text/html")
      |> fetch_query_params()
      |> put_private(:plug_skip_csrf_protection, true)
      |> init_test_session(%{})
      |> put_private(:phoenix_endpoint, BeamClaw.Gateway.Endpoint)
      |> put_private(:phoenix_router, BeamClaw.Gateway.Router)
      |> put_private(:phoenix_flash, %{})
      |> BeamClaw.Gateway.Router.call(@opts)

    assert conn.status == 200
    assert conn.resp_body =~ "BeamClaw"
  end

  test "unmatched route raises NoRouteError" do
    assert_raise Phoenix.Router.NoRouteError, fn ->
      conn(:get, "/nonexistent")
      |> put_req_header("accept", "application/json")
      |> BeamClaw.Gateway.Router.call(@opts)
    end
  end
end
