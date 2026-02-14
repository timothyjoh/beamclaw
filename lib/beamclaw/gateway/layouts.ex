defmodule BeamClaw.Gateway.Layouts do
  use Phoenix.Component

  import Phoenix.Controller,
    only: [get_csrf_token: 0]

  alias Phoenix.LiveView.JS

  embed_templates "layouts/*"

  attr :flash, :map, required: true

  def flash_group(assigns) do
    ~H"""
    <div id="flash-group" phx-update="replace">
      <div
        :for={{kind, msg} <- @flash}
        id={"flash-#{kind}"}
        phx-click={JS.push("lv:clear-flash") |> JS.remove_class("show", to: "#flash-#{kind}")}
        class={"flash-#{kind} show"}
      >
        <p><%= msg %></p>
      </div>
    </div>
    """
  end
end
