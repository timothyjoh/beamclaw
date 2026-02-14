defmodule BeamClaw.TenantTest do
  use ExUnit.Case, async: false

  alias BeamClaw.Tenant
  alias BeamClaw.Tenant.Manager
  alias BeamClaw.Tenant.Supervisor, as: TenantSupervisor

  setup do
    # Clean up any existing tenants before each test
    for tenant <- Manager.list_tenants() do
      Manager.delete_tenant(tenant.id)
    end

    :ok
  end

  describe "Tenant struct" do
    test "creates a new tenant with required fields" do
      tenant = Tenant.new(id: "test-1", name: "Test Corp")

      assert tenant.id == "test-1"
      assert tenant.name == "Test Corp"
      assert tenant.config == %{}
      assert tenant.status == :active
      assert %DateTime{} = tenant.created_at
    end

    test "creates a tenant with custom config and status" do
      tenant =
        Tenant.new(
          id: "test-2",
          name: "Test Corp 2",
          config: %{max_sessions: 100},
          status: :suspended
        )

      assert tenant.config == %{max_sessions: 100}
      assert tenant.status == :suspended
    end

    test "raises ArgumentError when id is missing" do
      assert_raise ArgumentError, "id is required", fn ->
        Tenant.new(name: "Test Corp")
      end
    end

    test "raises ArgumentError when name is missing" do
      assert_raise ArgumentError, "name is required", fn ->
        Tenant.new(id: "test-1")
      end
    end
  end

  describe "Tenant.Manager" do
    test "creates a tenant successfully" do
      assert {:ok, tenant} = Manager.create_tenant(id: "tenant-1", name: "Acme Corp")

      assert tenant.id == "tenant-1"
      assert tenant.name == "Acme Corp"
      assert tenant.status == :active
    end

    test "returns error when creating duplicate tenant" do
      assert {:ok, _} = Manager.create_tenant(id: "tenant-dup", name: "First")
      assert {:error, :already_exists} = Manager.create_tenant(id: "tenant-dup", name: "Second")
    end

    test "retrieves a tenant by ID" do
      assert {:ok, created} = Manager.create_tenant(id: "tenant-get", name: "Get Test")
      assert {:ok, retrieved} = Manager.get_tenant("tenant-get")

      assert retrieved.id == created.id
      assert retrieved.name == created.name
    end

    test "returns error when getting nonexistent tenant" do
      assert {:error, :not_found} = Manager.get_tenant("nonexistent")
    end

    test "lists all tenants" do
      assert {:ok, _} = Manager.create_tenant(id: "tenant-list-1", name: "List 1")
      assert {:ok, _} = Manager.create_tenant(id: "tenant-list-2", name: "List 2")

      tenants = Manager.list_tenants()
      tenant_ids = Enum.map(tenants, & &1.id)

      assert length(tenants) >= 2
      assert "tenant-list-1" in tenant_ids
      assert "tenant-list-2" in tenant_ids
    end

    test "deletes a tenant successfully" do
      assert {:ok, _} = Manager.create_tenant(id: "tenant-del", name: "Delete Test")
      assert :ok = Manager.delete_tenant("tenant-del")
      assert {:error, :not_found} = Manager.get_tenant("tenant-del")
    end

    test "returns error when deleting nonexistent tenant" do
      assert {:error, :not_found} = Manager.delete_tenant("nonexistent")
    end

    test "tenant is registered in BeamClaw.Registry" do
      assert {:ok, tenant} = Manager.create_tenant(id: "tenant-reg", name: "Registry Test")

      assert [{_pid, ^tenant}] = Registry.lookup(BeamClaw.Registry, {:tenant, "tenant-reg"})
    end

    test "tenant is unregistered after deletion" do
      assert {:ok, _} = Manager.create_tenant(id: "tenant-unreg", name: "Unregister Test")
      assert :ok = Manager.delete_tenant("tenant-unreg")

      assert [] = Registry.lookup(BeamClaw.Registry, {:tenant, "tenant-unreg"})
    end
  end

  describe "Tenant.Supervisor" do
    test "starts isolated session supervisor for tenant" do
      assert {:ok, _} = Manager.create_tenant(id: "tenant-session", name: "Session Test")

      session_sup = TenantSupervisor.session_supervisor("tenant-session")
      assert is_pid(session_sup)
      assert Process.alive?(session_sup)
    end

    test "starts isolated channel supervisor for tenant" do
      assert {:ok, _} = Manager.create_tenant(id: "tenant-channel", name: "Channel Test")

      channel_sup = TenantSupervisor.channel_supervisor("tenant-channel")
      assert is_pid(channel_sup)
      assert Process.alive?(channel_sup)
    end

    test "starts isolated cron supervisor for tenant" do
      assert {:ok, _} = Manager.create_tenant(id: "tenant-cron", name: "Cron Test")

      cron_sup = TenantSupervisor.cron_supervisor("tenant-cron")
      assert is_pid(cron_sup)
      assert Process.alive?(cron_sup)
    end

    test "starts isolated tool supervisor for tenant" do
      assert {:ok, _} = Manager.create_tenant(id: "tenant-tool", name: "Tool Test")

      tool_sup = TenantSupervisor.tool_supervisor("tenant-tool")
      assert is_pid(tool_sup)
      assert Process.alive?(tool_sup)
    end

    test "tenant supervisors are terminated when tenant is deleted" do
      assert {:ok, _} = Manager.create_tenant(id: "tenant-cleanup", name: "Cleanup Test")

      session_sup = TenantSupervisor.session_supervisor("tenant-cleanup")
      channel_sup = TenantSupervisor.channel_supervisor("tenant-cleanup")
      cron_sup = TenantSupervisor.cron_supervisor("tenant-cleanup")
      tool_sup = TenantSupervisor.tool_supervisor("tenant-cleanup")

      assert is_pid(session_sup)
      assert is_pid(channel_sup)
      assert is_pid(cron_sup)
      assert is_pid(tool_sup)

      assert :ok = Manager.delete_tenant("tenant-cleanup")

      # Wait a bit for processes to terminate
      Process.sleep(100)

      refute Process.alive?(session_sup)
      refute Process.alive?(channel_sup)
      refute Process.alive?(cron_sup)
      refute Process.alive?(tool_sup)
    end

    test "multiple tenants have isolated supervisors" do
      assert {:ok, _} = Manager.create_tenant(id: "tenant-iso-1", name: "Isolated 1")
      assert {:ok, _} = Manager.create_tenant(id: "tenant-iso-2", name: "Isolated 2")

      session_sup_1 = TenantSupervisor.session_supervisor("tenant-iso-1")
      session_sup_2 = TenantSupervisor.session_supervisor("tenant-iso-2")

      # Different tenants should have different supervisor PIDs
      assert session_sup_1 != session_sup_2
      assert is_pid(session_sup_1)
      assert is_pid(session_sup_2)
    end

    test "returns nil for supervisors of nonexistent tenant" do
      assert is_nil(TenantSupervisor.session_supervisor("nonexistent"))
      assert is_nil(TenantSupervisor.channel_supervisor("nonexistent"))
      assert is_nil(TenantSupervisor.cron_supervisor("nonexistent"))
      assert is_nil(TenantSupervisor.tool_supervisor("nonexistent"))
    end
  end

  describe "integration" do
    test "full tenant lifecycle: create, use, delete" do
      # Create tenant
      assert {:ok, tenant} =
               Manager.create_tenant(
                 id: "lifecycle-test",
                 name: "Lifecycle Corp",
                 config: %{feature_flags: [:advanced_tools]}
               )

      assert tenant.id == "lifecycle-test"
      assert tenant.config == %{feature_flags: [:advanced_tools]}

      # Verify all supervisors are running
      assert is_pid(TenantSupervisor.session_supervisor("lifecycle-test"))
      assert is_pid(TenantSupervisor.channel_supervisor("lifecycle-test"))
      assert is_pid(TenantSupervisor.cron_supervisor("lifecycle-test"))
      assert is_pid(TenantSupervisor.tool_supervisor("lifecycle-test"))

      # Verify tenant is in the list
      tenants = Manager.list_tenants()
      assert Enum.any?(tenants, &(&1.id == "lifecycle-test"))

      # Retrieve tenant
      assert {:ok, retrieved} = Manager.get_tenant("lifecycle-test")
      assert retrieved.id == "lifecycle-test"

      # Delete tenant
      assert :ok = Manager.delete_tenant("lifecycle-test")

      # Verify tenant is gone
      assert {:error, :not_found} = Manager.get_tenant("lifecycle-test")
      tenants_after = Manager.list_tenants()
      refute Enum.any?(tenants_after, &(&1.id == "lifecycle-test"))
    end
  end
end
