defmodule BeamClaw.Tenant do
  @moduledoc """
  Struct representing a tenant in the multi-tenant BeamClaw system.

  Each tenant has isolated supervision subtrees for sessions, channels, cron workers,
  and tool execution.
  """

  @type status :: :active | :suspended | :deleted
  @type t :: %__MODULE__{
          id: String.t(),
          name: String.t(),
          config: map(),
          status: status(),
          created_at: DateTime.t()
        }

  @enforce_keys [:id, :name]
  defstruct [:id, :name, config: %{}, status: :active, created_at: nil]

  @doc """
  Creates a new tenant struct.

  ## Options
    * `:id` - Unique tenant identifier (required)
    * `:name` - Human-readable tenant name (required)
    * `:config` - Tenant-specific configuration (optional, defaults to %{})
    * `:status` - Tenant status (optional, defaults to :active)
    * `:created_at` - Creation timestamp (optional, defaults to current UTC time)

  ## Examples

      iex> BeamClaw.Tenant.new(id: "tenant-1", name: "Acme Corp")
      %BeamClaw.Tenant{id: "tenant-1", name: "Acme Corp", config: %{}, status: :active}
  """
  def new(attrs) do
    %__MODULE__{
      id: attrs[:id] || raise(ArgumentError, "id is required"),
      name: attrs[:name] || raise(ArgumentError, "name is required"),
      config: attrs[:config] || %{},
      status: attrs[:status] || :active,
      created_at: attrs[:created_at] || DateTime.utc_now()
    }
  end
end
