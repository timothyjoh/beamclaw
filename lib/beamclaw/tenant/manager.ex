defmodule BeamClaw.Tenant.Manager do
  @moduledoc """
  GenServer for managing tenant lifecycle.

  Handles creating, retrieving, listing, and deleting tenants.
  Each tenant is registered in BeamClaw.Registry with {:tenant, tenant_id}.
  """

  use GenServer
  require Logger

  # Client API

  @doc """
  Starts the tenant manager.
  """
  def start_link(_opts) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  @doc """
  Creates a new tenant and starts its supervision subtree.

  ## Examples

      iex> BeamClaw.Tenant.Manager.create_tenant(id: "tenant-1", name: "Acme Corp")
      {:ok, %BeamClaw.Tenant{id: "tenant-1", name: "Acme Corp"}}

      iex> BeamClaw.Tenant.Manager.create_tenant(id: "tenant-1", name: "Duplicate")
      {:error, :already_exists}
  """
  def create_tenant(attrs) do
    GenServer.call(__MODULE__, {:create_tenant, attrs})
  end

  @doc """
  Retrieves a tenant by ID.

  ## Examples

      iex> BeamClaw.Tenant.Manager.get_tenant("tenant-1")
      {:ok, %BeamClaw.Tenant{id: "tenant-1"}}

      iex> BeamClaw.Tenant.Manager.get_tenant("nonexistent")
      {:error, :not_found}
  """
  def get_tenant(tenant_id) do
    GenServer.call(__MODULE__, {:get_tenant, tenant_id})
  end

  @doc """
  Lists all tenants.

  ## Examples

      iex> BeamClaw.Tenant.Manager.list_tenants()
      [%BeamClaw.Tenant{id: "tenant-1"}, %BeamClaw.Tenant{id: "tenant-2"}]
  """
  def list_tenants do
    GenServer.call(__MODULE__, :list_tenants)
  end

  @doc """
  Deletes a tenant and terminates its supervision subtree.

  ## Examples

      iex> BeamClaw.Tenant.Manager.delete_tenant("tenant-1")
      :ok

      iex> BeamClaw.Tenant.Manager.delete_tenant("nonexistent")
      {:error, :not_found}
  """
  def delete_tenant(tenant_id) do
    GenServer.call(__MODULE__, {:delete_tenant, tenant_id})
  end

  # Server Callbacks

  @impl true
  def init(_opts) do
    {:ok, %{}}
  end

  @impl true
  def handle_call({:create_tenant, attrs}, _from, state) do
    tenant_id = attrs[:id]

    if Map.has_key?(state, tenant_id) do
      {:reply, {:error, :already_exists}, state}
    else
      case do_create_tenant(attrs) do
        {:ok, tenant} ->
          # Register tenant in BeamClaw.Registry
          Registry.register(BeamClaw.Registry, {:tenant, tenant_id}, tenant)

          new_state = Map.put(state, tenant_id, tenant)
          {:reply, {:ok, tenant}, new_state}

        {:error, reason} ->
          {:reply, {:error, reason}, state}
      end
    end
  end

  @impl true
  def handle_call({:get_tenant, tenant_id}, _from, state) do
    case Map.fetch(state, tenant_id) do
      {:ok, tenant} -> {:reply, {:ok, tenant}, state}
      :error -> {:reply, {:error, :not_found}, state}
    end
  end

  @impl true
  def handle_call(:list_tenants, _from, state) do
    tenants = Map.values(state)
    {:reply, tenants, state}
  end

  @impl true
  def handle_call({:delete_tenant, tenant_id}, _from, state) do
    case Map.fetch(state, tenant_id) do
      {:ok, tenant} ->
        # Delete tenant supervisor and all its children
        :ok = do_delete_tenant(tenant)

        # Unregister from BeamClaw.Registry
        Registry.unregister(BeamClaw.Registry, {:tenant, tenant_id})

        new_state = Map.delete(state, tenant_id)
        {:reply, :ok, new_state}

      :error ->
        {:reply, {:error, :not_found}, state}
    end
  end

  # Private Helpers

  defp do_create_tenant(attrs) do
    try do
      tenant = BeamClaw.Tenant.new(attrs)

      # Start tenant supervisor under BeamClaw.TenantSupervisor
      case DynamicSupervisor.start_child(
             BeamClaw.TenantSupervisor,
             {BeamClaw.Tenant.Supervisor, tenant}
           ) do
        {:ok, _pid} ->
          Logger.info("Created tenant: #{tenant.id}")
          {:ok, tenant}

        {:error, reason} ->
          Logger.error("Failed to start tenant supervisor: #{inspect(reason)}")
          {:error, reason}
      end
    rescue
      e in ArgumentError ->
        {:error, e.message}
    end
  end

  defp do_delete_tenant(tenant) do
    # Look up the tenant supervisor PID
    case Registry.lookup(BeamClaw.Registry, {:tenant_supervisor, tenant.id}) do
      [{pid, _}] ->
        # Terminate the tenant supervisor (and all its children)
        DynamicSupervisor.terminate_child(BeamClaw.TenantSupervisor, pid)
        Logger.info("Deleted tenant: #{tenant.id}")
        :ok

      [] ->
        Logger.warning("Tenant supervisor not found for: #{tenant.id}")
        :ok
    end
  end
end
