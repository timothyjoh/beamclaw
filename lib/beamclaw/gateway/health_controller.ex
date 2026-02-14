defmodule BeamClaw.Gateway.HealthController do
  use Phoenix.Controller, formats: [:json]

  @doc """
  GET /health

  Returns health status, session count, and uptime.
  """
  def index(conn, _params) do
    # Count active sessions in the Registry
    all_keys = Registry.select(BeamClaw.Registry, [{{:"$1", :"$2", :"$3"}, [], [:"$1"]}])

    session_count =
      Enum.count(all_keys, fn
        {:session, _} -> true
        _ -> false
      end)

    # Get system uptime in seconds
    uptime_seconds = System.monotonic_time(:second)

    json(conn, %{
      status: "ok",
      sessions: session_count,
      uptime_seconds: uptime_seconds
    })
  end
end
