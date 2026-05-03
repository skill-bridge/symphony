defmodule SymphonyElixir.Claude.ToolTrackerTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Claude.ToolTracker

  setup do
    ToolTracker.clear()
    on_exit(fn -> :ok end)
    :ok
  end

  test "begin/finish round-trip surfaces the tool name and a positive duration" do
    :ok = ToolTracker.begin("tu-1", "Read")
    Process.sleep(2)

    assert %{name: "Read", duration_ms: dur} = ToolTracker.finish("tu-1")
    assert is_integer(dur)
    assert dur >= 0
  end

  test "finish for an unregistered id returns nil" do
    assert ToolTracker.finish("nope") == nil
  end

  test "clear empties the in-flight table" do
    ToolTracker.begin("tu-a", "Bash")
    ToolTracker.begin("tu-b", "Read")
    assert ToolTracker.stats().in_flight == 2

    ToolTracker.clear()
    assert ToolTracker.stats().in_flight == 0
  end

  test "begin twice with the same id keeps the latest registration (last write wins)" do
    ToolTracker.begin("tu-x", "OldTool")
    Process.sleep(5)
    ToolTracker.begin("tu-x", "NewTool")

    assert %{name: "NewTool"} = ToolTracker.finish("tu-x")
    # second finish exhausts the entry
    assert ToolTracker.finish("tu-x") == nil
  end

  test "stats reports zero before any begin and increments per registration" do
    assert ToolTracker.stats() == %{in_flight: 0}

    ToolTracker.begin("tu-1", "A")
    ToolTracker.begin("tu-2", "B")
    assert ToolTracker.stats() == %{in_flight: 2}

    ToolTracker.finish("tu-1")
    assert ToolTracker.stats() == %{in_flight: 1}
  end

  test "tracking is scoped to the calling process — siblings cannot see each other" do
    parent = self()

    spawn_link(fn ->
      ToolTracker.begin("isolated-id", "RemoteTool")
      send(parent, {:registered, ToolTracker.stats()})
      send(parent, {:finish, ToolTracker.finish("isolated-id")})
    end)

    assert_receive {:registered, %{in_flight: 1}}
    assert_receive {:finish, %{name: "RemoteTool"}}

    # parent's table is untouched
    assert ToolTracker.stats() == %{in_flight: 0}
    assert ToolTracker.finish("isolated-id") == nil
  end

  test "finish is idempotent — repeated calls after the first return nil" do
    ToolTracker.begin("once", "Once")
    assert %{name: "Once"} = ToolTracker.finish("once")
    assert ToolTracker.finish("once") == nil
    assert ToolTracker.finish("once") == nil
  end
end
