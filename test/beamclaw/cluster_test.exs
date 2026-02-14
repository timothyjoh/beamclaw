defmodule BeamClaw.ClusterTest do
  use ExUnit.Case, async: true

  alias BeamClaw.Cluster

  describe "node management" do
    test "node_list/0 returns list of connected nodes" do
      # In test environment, typically no connected nodes
      nodes = Cluster.node_list()
      assert is_list(nodes)
    end

    test "node_count/0 returns total node count including local" do
      # Should be at least 1 (local node)
      count = Cluster.node_count()
      assert count >= 1
      # In single-node test, should be exactly 1
      assert count == length(Cluster.node_list()) + 1
    end

    test "local_node/0 returns current node name" do
      node = Cluster.local_node()
      assert is_atom(node)
      assert node == Node.self()
    end

    test "connected?/0 returns false when no nodes connected" do
      # In test environment, no cluster connections
      assert Cluster.connected?() == false
    end

    test "connected?/0 returns true if nodes are connected" do
      # When node_list is not empty, should be true
      # This is true by definition: connected? == (node_list != [])
      assert Cluster.connected?() == (Cluster.node_list() != [])
    end
  end

  describe "pg scope" do
    test "pg_scope/0 returns the beamclaw scope atom" do
      assert Cluster.pg_scope() == :beamclaw
    end
  end

  describe "process groups" do
    test "join/1 adds current process to a group" do
      group = :test_group_1
      assert :ok = Cluster.join(group)

      members = Cluster.members(group)
      assert self() in members
    end

    test "join/2 adds specified process to a group" do
      group = :test_group_2
      {:ok, pid} = Task.start(fn -> Process.sleep(:infinity) end)

      assert :ok = Cluster.join(group, pid)

      members = Cluster.members(group)
      assert pid in members

      # Cleanup
      Process.exit(pid, :kill)
    end

    test "leave/1 removes current process from a group" do
      group = :test_group_3
      Cluster.join(group)
      assert self() in Cluster.members(group)

      assert :ok = Cluster.leave(group)
      refute self() in Cluster.members(group)
    end

    test "leave/2 removes specified process from a group" do
      group = :test_group_4
      {:ok, pid} = Task.start(fn -> Process.sleep(:infinity) end)

      Cluster.join(group, pid)
      assert pid in Cluster.members(group)

      assert :ok = Cluster.leave(group, pid)
      refute pid in Cluster.members(group)

      # Cleanup
      Process.exit(pid, :kill)
    end

    test "members/1 returns all members of a group" do
      group = :test_group_5
      Cluster.join(group)

      members = Cluster.members(group)
      assert is_list(members)
      assert self() in members
    end

    test "local_members/1 returns local members of a group" do
      group = :test_group_6
      Cluster.join(group)

      local_members = Cluster.local_members(group)
      assert is_list(local_members)
      assert self() in local_members

      # In single-node test, local_members should equal members
      assert local_members == Cluster.members(group)
    end

    test "which_groups/0 returns all process groups" do
      group = :test_group_7
      Cluster.join(group)

      groups = Cluster.which_groups()
      assert is_list(groups)
      assert group in groups
    end

    test "multiple processes can join the same group" do
      group = :test_group_8
      {:ok, pid1} = Task.start(fn -> Process.sleep(:infinity) end)
      {:ok, pid2} = Task.start(fn -> Process.sleep(:infinity) end)

      Cluster.join(group, pid1)
      Cluster.join(group, pid2)

      members = Cluster.members(group)
      assert pid1 in members
      assert pid2 in members
      assert length(members) >= 2

      # Cleanup
      Process.exit(pid1, :kill)
      Process.exit(pid2, :kill)
    end

    test "process automatically leaves group when it dies" do
      group = :test_group_9
      {:ok, pid} = Task.start(fn -> Process.sleep(:infinity) end)

      Cluster.join(group, pid)
      assert pid in Cluster.members(group)

      Process.exit(pid, :kill)
      # Give :pg time to detect the exit
      Process.sleep(10)

      refute pid in Cluster.members(group)
    end

    test "members/1 returns empty list for non-existent group" do
      group = :nonexistent_group_12345
      members = Cluster.members(group)
      assert members == []
    end
  end
end
