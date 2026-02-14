defmodule BeamClaw.Phase6aIntegrationTest do
  @moduledoc """
  Integration tests for Phase 6a: Multi-Tenant Foundation.

  Tests that tenant isolation, telemetry events, and cluster module
  all work together in the running application.
  """

  use ExUnit.Case, async: false

  alias BeamClaw.Tenant.Manager
  alias BeamClaw.Tenant.Supervisor, as: TenantSupervisor

  setup do
    # Clean up any tenants created during tests
    on_exit(fn ->
      for tenant <- Manager.list_tenants() do
        Manager.delete_tenant(tenant.id)
      end
    end)

    :ok
  end

  describe "tenant creation with isolated supervision" do
    test "creates a tenant with all 4 isolated supervisors" do
      {:ok, tenant} = Manager.create_tenant(id: "integ-1", name: "Integration Tenant")

      assert tenant.id == "integ-1"
      assert tenant.name == "Integration Tenant"
      assert tenant.status == :active

      # Verify all 4 per-tenant supervisors are running
      assert is_pid(TenantSupervisor.session_supervisor("integ-1"))
      assert is_pid(TenantSupervisor.channel_supervisor("integ-1"))
      assert is_pid(TenantSupervisor.cron_supervisor("integ-1"))
      assert is_pid(TenantSupervisor.tool_supervisor("integ-1"))
    end

    test "tenant supervisors are isolated from each other" do
      {:ok, _t1} = Manager.create_tenant(id: "iso-a", name: "Tenant A")
      {:ok, _t2} = Manager.create_tenant(id: "iso-b", name: "Tenant B")

      # Each tenant has distinct supervisor PIDs
      a_sessions = TenantSupervisor.session_supervisor("iso-a")
      b_sessions = TenantSupervisor.session_supervisor("iso-b")
      assert a_sessions != b_sessions
      assert Process.alive?(a_sessions)
      assert Process.alive?(b_sessions)

      # Deleting tenant A doesn't affect tenant B
      :ok = Manager.delete_tenant("iso-a")
      assert is_nil(TenantSupervisor.session_supervisor("iso-a"))
      assert Process.alive?(b_sessions)
    end

    test "tenant registered in BeamClaw.Registry" do
      {:ok, _tenant} = Manager.create_tenant(id: "reg-1", name: "Registered Tenant")

      # Tenant is findable in the registry
      assert [{_pid, _value}] = Registry.lookup(BeamClaw.Registry, {:tenant, "reg-1"})
    end
  end

  describe "telemetry events fire on key operations" do
    test "session telemetry events emit correctly" do
      ref = make_ref()
      test_pid = self()

      handler = fn event, measurements, metadata, _config ->
        send(test_pid, {ref, event, measurements, metadata})
      end

      :telemetry.attach("integ-session-start", [:beamclaw, :session, :start], handler, nil)
      :telemetry.attach("integ-session-stop", [:beamclaw, :session, :stop], handler, nil)

      on_exit(fn ->
        :telemetry.detach("integ-session-start")
        :telemetry.detach("integ-session-stop")
      end)

      # Emit session start
      BeamClaw.Telemetry.emit_session_start(%{session_key: "agent:test:main", agent_id: "test"})
      assert_receive {^ref, [:beamclaw, :session, :start], %{system_time: _}, %{session_key: "agent:test:main"}}

      # Emit session stop
      BeamClaw.Telemetry.emit_session_stop(%{session_key: "agent:test:main", duration: 1000})
      assert_receive {^ref, [:beamclaw, :session, :stop], %{duration: 1000}, %{session_key: "agent:test:main"}}
    end

    test "tenant telemetry events emit on create/delete" do
      ref = make_ref()
      test_pid = self()

      handler = fn event, measurements, metadata, _config ->
        send(test_pid, {ref, event, measurements, metadata})
      end

      :telemetry.attach("integ-tenant-create", [:beamclaw, :tenant, :create], handler, nil)
      :telemetry.attach("integ-tenant-delete", [:beamclaw, :tenant, :delete], handler, nil)

      on_exit(fn ->
        :telemetry.detach("integ-tenant-create")
        :telemetry.detach("integ-tenant-delete")
      end)

      # Emit tenant create
      BeamClaw.Telemetry.emit_tenant_create(%{tenant_id: "tel-1"})
      assert_receive {^ref, [:beamclaw, :tenant, :create], %{count: 1}, %{tenant_id: "tel-1"}}

      # Emit tenant delete
      BeamClaw.Telemetry.emit_tenant_delete(%{tenant_id: "tel-1"})
      assert_receive {^ref, [:beamclaw, :tenant, :delete], %{count: 1}, %{tenant_id: "tel-1"}}
    end

    test "provider and tool telemetry events emit correctly" do
      ref = make_ref()
      test_pid = self()

      handler = fn event, measurements, metadata, _config ->
        send(test_pid, {ref, event, measurements, metadata})
      end

      :telemetry.attach("integ-provider-start", [:beamclaw, :provider, :request, :start], handler, nil)
      :telemetry.attach("integ-tool-start", [:beamclaw, :tool, :execute, :start], handler, nil)

      on_exit(fn ->
        :telemetry.detach("integ-provider-start")
        :telemetry.detach("integ-tool-start")
      end)

      BeamClaw.Telemetry.emit_provider_request_start(%{provider: :anthropic, model: "claude-sonnet-4-5-20250929"})
      assert_receive {^ref, [:beamclaw, :provider, :request, :start], _, %{provider: :anthropic}}

      BeamClaw.Telemetry.emit_tool_execute_start(%{tool_name: "exec", session_key: "test:main"})
      assert_receive {^ref, [:beamclaw, :tool, :execute, :start], _, %{tool_name: "exec"}}
    end

    test "telemetry metrics list is populated" do
      metrics = BeamClaw.Telemetry.metrics()
      assert length(metrics) > 10

      metric_names = Enum.map(metrics, & &1.name)
      assert [:beamclaw, :session, :start, :total] in metric_names
      assert [:beamclaw, :provider, :request, :stop, :duration] in metric_names
      assert [:beamclaw, :tenant, :create, :total] in metric_names
      assert [:vm, :memory, :total] in metric_names
    end
  end

  describe "cluster module" do
    test "reports node info in single-node mode" do
      assert BeamClaw.Cluster.node_count() == 1
      assert BeamClaw.Cluster.node_list() == []
      assert is_atom(BeamClaw.Cluster.local_node())
      assert BeamClaw.Cluster.connected?() == false
    end

    test ":pg process groups work" do
      # Join a group
      :ok = BeamClaw.Cluster.join(:test_group)
      assert self() in BeamClaw.Cluster.members(:test_group)
      assert self() in BeamClaw.Cluster.local_members(:test_group)
      assert :test_group in BeamClaw.Cluster.which_groups()

      # Leave the group
      :ok = BeamClaw.Cluster.leave(:test_group)
      refute self() in BeamClaw.Cluster.members(:test_group)
    end

    test ":pg scope is :beamclaw" do
      assert BeamClaw.Cluster.pg_scope() == :beamclaw
    end
  end

  describe "LiveDashboard route" do
    test "/dashboard route exists in router" do
      # Verify the LiveDashboard route is defined by checking the router
      # We test the route exists without needing full session/CSRF setup
      routes = BeamClaw.Gateway.Router.__routes__()
      dashboard_routes = Enum.filter(routes, fn r -> String.starts_with?(r.path, "/dashboard") end)
      assert length(dashboard_routes) > 0, "Expected /dashboard routes to be defined"
    end

    test "telemetry module defines metrics for LiveDashboard" do
      # LiveDashboard uses BeamClaw.Telemetry.metrics/0
      metrics = BeamClaw.Telemetry.metrics()
      assert is_list(metrics)
      assert length(metrics) > 0
    end
  end

  describe "full integration: tenant + telemetry + cluster" do
    test "creating a tenant, verifying isolation, checking cluster state" do
      # Step 1: Create tenant
      {:ok, tenant} = Manager.create_tenant(id: "full-integ", name: "Full Integration")
      assert tenant.status == :active

      # Step 2: Verify isolation — all supervisors alive
      session_sup = TenantSupervisor.session_supervisor("full-integ")
      assert Process.alive?(session_sup)

      # Step 3: Cluster module works alongside tenant
      assert BeamClaw.Cluster.node_count() == 1
      :ok = BeamClaw.Cluster.join({:tenant_sessions, "full-integ"})
      assert self() in BeamClaw.Cluster.members({:tenant_sessions, "full-integ"})
      :ok = BeamClaw.Cluster.leave({:tenant_sessions, "full-integ"})

      # Step 4: Clean up
      :ok = Manager.delete_tenant("full-integ")
      assert {:error, :not_found} = Manager.get_tenant("full-integ")
    end
  end
end
