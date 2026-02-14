defmodule BeamClaw.Cluster do
  @moduledoc """
  Cluster management for distributed BeamClaw nodes.

  Provides utilities for node discovery and process group management
  using Erlang's :pg module for distributed process groups.
  """

  @pg_scope :beamclaw

  @doc "Returns the pg scope used for BeamClaw process groups"
  def pg_scope, do: @pg_scope

  @doc "Returns list of connected nodes (excluding local node)"
  def node_list do
    Node.list()
  end

  @doc "Returns total node count (connected nodes + local node)"
  def node_count do
    length(Node.list()) + 1
  end

  @doc "Returns the local node name"
  def local_node do
    Node.self()
  end

  @doc "Returns true if connected to any remote nodes"
  def connected? do
    Node.list() != []
  end

  # Process group helpers using :pg

  @doc "Join a process group. Defaults to current process."
  def join(group, pid \\ self()) do
    :pg.join(@pg_scope, group, pid)
  end

  @doc "Leave a process group. Defaults to current process."
  def leave(group, pid \\ self()) do
    :pg.leave(@pg_scope, group, pid)
  end

  @doc "Get all members of a process group across all nodes"
  def members(group) do
    :pg.get_members(@pg_scope, group)
  end

  @doc "Get local members of a process group (only on this node)"
  def local_members(group) do
    :pg.get_local_members(@pg_scope, group)
  end

  @doc "Returns all process groups in the cluster"
  def which_groups do
    :pg.which_groups(@pg_scope)
  end
end
