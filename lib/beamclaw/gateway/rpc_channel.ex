defmodule BeamClaw.Gateway.RPCChannel do
  use Phoenix.Channel
  require Logger

  def join("rpc:lobby", params, socket) do
    device_id = Map.get(params, "deviceId", "anonymous")
    Phoenix.PubSub.subscribe(BeamClaw.PubSub, "events:global")
    Logger.info("RPC client connected: #{device_id}")
    {:ok, assign(socket, :device_id, device_id)}
  end

  # Client sends RPC request
  def handle_in("request", %{"id" => id, "method" => method, "params" => params}, socket) do
    result = route_rpc(method, params || %{})
    {:reply, {:ok, %{id: id, result: result}}, socket}
  end

  # Server-pushed events via PubSub
  def handle_info({:push_event, event, data}, socket) do
    push(socket, "event", %{event: event, data: data})
    {:noreply, socket}
  end

  # RPC method routing
  defp route_rpc("gateway.status", _params) do
    sessions = Registry.select(BeamClaw.Registry, [{{:"$1", :"$2", :"$3"}, [], [:"$1"]}])
    session_count = Enum.count(sessions, fn {:session, _} -> true; _ -> false end)
    %{status: "ok", sessions: session_count, uptime: System.monotonic_time(:second)}
  end

  defp route_rpc("sessions.list", _params) do
    sessions = Registry.select(BeamClaw.Registry, [{{:"$1", :"$2", :"$3"}, [], [:"$1"]}])
    session_keys = for {:session, key} <- sessions, do: key
    %{sessions: session_keys}
  end

  defp route_rpc("sessions.create", %{"name" => name}) do
    case BeamClaw.new_session(name) do
      {:ok, _pid} -> %{status: "created", session_key: "agent:default:#{name}"}
      {:error, {:already_started, _}} -> %{status: "exists", session_key: "agent:default:#{name}"}
      {:error, reason} -> %{error: inspect(reason)}
    end
  end

  defp route_rpc("sessions.create", _params) do
    route_rpc("sessions.create", %{"name" => "main"})
  end

  defp route_rpc("sessions.sendMessage", %{"sessionKey" => key, "message" => msg}) do
    BeamClaw.Session.send_message(key, msg)
    %{status: "sent", session_key: key}
  end

  defp route_rpc(method, _params) do
    %{error: "unknown_method", method: method}
  end
end
