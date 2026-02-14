defmodule BeamClaw.Gateway.DashboardLive do
  use Phoenix.LiveView

  @refresh_interval 2000

  def mount(_params, _session, socket) do
    # Subscribe to global events for session updates
    Phoenix.PubSub.subscribe(BeamClaw.PubSub, "events:global")

    # Schedule periodic refresh
    Process.send_after(self(), :refresh_sessions, @refresh_interval)

    socket =
      socket
      |> assign(:page_title, "BeamClaw Dashboard")
      |> assign(:sessions, list_sessions())
      |> assign(:selected, nil)
      |> assign(:messages, [])
      |> assign(:streaming_text, "")
      |> assign(:input, "")
      |> assign(:new_session_name, "")

    {:ok, socket}
  end

  # Event Handlers

  def handle_event("new_session", %{"name" => name}, socket) do
    case BeamClaw.new_session(name) do
      {:ok, _pid} ->
        session_key = "agent:default:#{name}"
        socket =
          socket
          |> assign(:sessions, list_sessions())
          |> assign(:selected, session_key)
          |> assign(:messages, [])
          |> assign(:streaming_text, "")
          |> assign(:new_session_name, "")
        {:noreply, socket}

      {:error, _reason} ->
        {:noreply, socket}
    end
  end

  def handle_event("select_session", %{"key" => key}, socket) do
    messages =
      try do
        BeamClaw.Session.get_history(key)
      catch
        _, _ -> []
      end

    socket =
      socket
      |> assign(:selected, key)
      |> assign(:messages, messages)
      |> assign(:streaming_text, "")

    {:noreply, socket}
  end

  def handle_event("send_message", %{"message" => text}, socket) do
    if socket.assigns.selected && text != "" do
      # Add user message to display immediately
      user_message = %{role: "user", content: text}
      messages = socket.assigns.messages ++ [user_message]

      # Send to session (will stream back to us)
      BeamClaw.Session.send_message(socket.assigns.selected, text)

      socket =
        socket
        |> assign(:messages, messages)
        |> assign(:input, "")
        |> assign(:streaming_text, "")

      {:noreply, socket}
    else
      {:noreply, socket}
    end
  end

  def handle_event("update_input", %{"input" => text}, socket) do
    {:noreply, assign(socket, :input, text)}
  end

  def handle_event("update_new_session_name", %{"name" => name}, socket) do
    {:noreply, assign(socket, :new_session_name, name)}
  end

  # Stream handlers

  def handle_info({:stream_chunk, session_key, text}, socket) do
    if socket.assigns.selected == session_key do
      streaming_text = socket.assigns.streaming_text <> text
      {:noreply, assign(socket, :streaming_text, streaming_text)}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:stream_done, session_key, full_text}, socket) do
    if socket.assigns.selected == session_key do
      assistant_message = %{role: "assistant", content: full_text}
      messages = socket.assigns.messages ++ [assistant_message]

      socket =
        socket
        |> assign(:messages, messages)
        |> assign(:streaming_text, "")

      {:noreply, socket}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:stream_error, session_key, reason}, socket) do
    if socket.assigns.selected == session_key do
      error_message = %{role: "assistant", content: "[Error: #{inspect(reason)}]"}
      messages = socket.assigns.messages ++ [error_message]

      socket =
        socket
        |> assign(:messages, messages)
        |> assign(:streaming_text, "")

      {:noreply, socket}
    else
      {:noreply, socket}
    end
  end

  def handle_info(:refresh_sessions, socket) do
    # Schedule next refresh
    Process.send_after(self(), :refresh_sessions, @refresh_interval)

    # Update session list
    {:noreply, assign(socket, :sessions, list_sessions())}
  end

  # Catch-all for PubSub messages we don't specifically handle
  def handle_info(_msg, socket) do
    {:noreply, socket}
  end

  # Helpers

  defp list_sessions do
    Registry.select(BeamClaw.Registry, [{{:"$1", :"$2", :"$3"}, [], [{{:"$1", :"$2"}}]}])
    |> Enum.filter(fn {{:session, _key}, _pid} -> true; _ -> false end)
    |> Enum.map(fn {{:session, key}, pid} ->
      state =
        try do
          GenServer.call(pid, :get_state, 1000)
        catch
          _, _ -> nil
        end

      %{
        key: key,
        status: if(state, do: state.status, else: :unknown),
        message_count: if(state, do: length(state.messages), else: 0)
      }
    end)
  end

  # Template

  def render(assigns) do
    ~H"""
    <div class="flex h-screen">
      <!-- Sidebar -->
      <div class="w-64 bg-gray-800 border-r border-gray-700 flex flex-col">
        <div class="p-4 border-b border-gray-700">
          <h1 class="text-xl font-bold">BeamClaw</h1>
          <p class="text-xs text-gray-400">Session Dashboard</p>
        </div>

        <!-- New Session Form -->
        <div class="p-4 border-b border-gray-700">
          <form phx-submit="new_session" class="space-y-2">
            <input
              type="text"
              name="name"
              value={@new_session_name}
              phx-change="update_new_session_name"
              placeholder="Session name..."
              class="w-full px-3 py-2 bg-gray-700 border border-gray-600 rounded text-sm text-white placeholder-gray-400 focus:outline-none focus:border-blue-500"
            />
            <button
              type="submit"
              class="w-full px-3 py-2 bg-blue-600 hover:bg-blue-700 rounded text-sm font-medium transition-colors"
            >
              + New Session
            </button>
          </form>
        </div>

        <!-- Sessions List -->
        <div class="flex-1 overflow-y-auto">
          <div class="p-2">
            <div :if={@sessions == []} class="p-4 text-sm text-gray-400 text-center">
              No active sessions
            </div>
            <div
              :for={session <- @sessions}
              phx-click="select_session"
              phx-value-key={session.key}
              class={[
                "p-3 mb-1 rounded cursor-pointer transition-colors",
                if(@selected == session.key,
                  do: "bg-blue-600",
                  else: "bg-gray-700 hover:bg-gray-600"
                )
              ]}
            >
              <div class="flex items-center justify-between mb-1">
                <span class="text-sm font-medium truncate">
                  {session.key |> String.split(":") |> List.last()}
                </span>
                <span class={[
                  "text-xs px-2 py-0.5 rounded",
                  case session.status do
                    :processing -> "bg-yellow-600"
                    :idle -> "bg-green-600"
                    _ -> "bg-gray-600"
                  end
                ]}>
                  {session.status}
                </span>
              </div>
              <div class="text-xs text-gray-300">
                {session.message_count} messages
              </div>
            </div>
          </div>
        </div>
      </div>

      <!-- Main Chat Area -->
      <div class="flex-1 flex flex-col">
        <div :if={@selected == nil} class="flex-1 flex items-center justify-center text-gray-400">
          <div class="text-center">
            <svg
              class="w-16 h-16 mx-auto mb-4 opacity-50"
              fill="none"
              stroke="currentColor"
              viewBox="0 0 24 24"
            >
              <path
                stroke-linecap="round"
                stroke-linejoin="round"
                stroke-width="2"
                d="M8 12h.01M12 12h.01M16 12h.01M21 12c0 4.418-4.03 8-9 8a9.863 9.863 0 01-4.255-.949L3 20l1.395-3.72C3.512 15.042 3 13.574 3 12c0-4.418 4.03-8 9-8s9 3.582 9 8z"
              />
            </svg>
            <p class="text-lg">Select a session to start chatting</p>
          </div>
        </div>

        <div :if={@selected != nil} class="flex-1 flex flex-col">
          <!-- Chat Header -->
          <div class="p-4 border-b border-gray-700 bg-gray-800">
            <h2 class="font-semibold">{@selected}</h2>
          </div>

          <!-- Messages -->
          <div class="flex-1 overflow-y-auto p-4 space-y-4">
            <div :for={msg <- @messages} class="flex">
              <div class={[
                "max-w-2xl rounded-lg px-4 py-2",
                if(msg.role == "user",
                  do: "ml-auto bg-blue-600",
                  else: "mr-auto bg-gray-700"
                )
              ]}>
                <div class="text-xs font-semibold mb-1 opacity-75">
                  {if msg.role == "user", do: "User", else: "Assistant"}
                </div>
                <div class="text-sm whitespace-pre-wrap">{msg.content}</div>
              </div>
            </div>

            <!-- Streaming Text -->
            <div :if={@streaming_text != ""} class="flex">
              <div class="max-w-2xl mr-auto bg-gray-700 rounded-lg px-4 py-2">
                <div class="text-xs font-semibold mb-1 opacity-75">Assistant</div>
                <div class="text-sm whitespace-pre-wrap">
                  {@streaming_text}<span class="inline-block w-2 h-4 bg-white animate-pulse ml-1"></span>
                </div>
              </div>
            </div>
          </div>

          <!-- Input Area -->
          <div class="p-4 border-t border-gray-700 bg-gray-800">
            <form phx-submit="send_message" class="flex gap-2">
              <input
                type="text"
                name="message"
                value={@input}
                phx-change="update_input"
                placeholder="Type a message..."
                class="flex-1 px-4 py-2 bg-gray-700 border border-gray-600 rounded text-white placeholder-gray-400 focus:outline-none focus:border-blue-500"
              />
              <button
                type="submit"
                class="px-6 py-2 bg-blue-600 hover:bg-blue-700 rounded font-medium transition-colors disabled:opacity-50 disabled:cursor-not-allowed"
                disabled={@input == ""}
              >
                Send
              </button>
            </form>
          </div>
        </div>
      </div>
    </div>
    """
  end
end
