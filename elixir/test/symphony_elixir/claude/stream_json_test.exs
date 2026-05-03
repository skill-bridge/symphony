defmodule SymphonyElixir.Claude.StreamJsonTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Claude.StreamJson

  test "decodes a single complete line" do
    state = StreamJson.new()

    assert {:ok, [%{"type" => "system", "subtype" => "init"}], state} =
             StreamJson.feed(state, ~s({"type":"system","subtype":"init"}\n))

    assert state.buffer == ""
  end

  test "preserves order across multiple newline-separated objects" do
    state = StreamJson.new()
    input = ~s({"a":1}\n{"b":2}\n{"c":3}\n)

    assert {:ok, parsed, state} = StreamJson.feed(state, input)
    assert parsed == [%{"a" => 1}, %{"b" => 2}, %{"c" => 3}]
    assert state.buffer == ""
  end

  test "buffers partial lines until terminator arrives" do
    state = StreamJson.new()

    assert {:ok, [], state} = StreamJson.feed(state, ~s({"a":1))
    assert state.buffer == ~s({"a":1)

    assert {:ok, [%{"a" => 1}, %{"b" => 2}], state} =
             StreamJson.feed(state, ~s(}\n{"b":2}\n))

    assert state.buffer == ""
  end

  test "yields malformed tuple for invalid JSON lines" do
    state = StreamJson.new()
    input = "not json\n"

    assert {:ok, [malformed], _state} = StreamJson.feed(state, input)
    assert {:malformed, "not json", _reason} = malformed
  end

  test "yields malformed tuple when decoded value is not a JSON object" do
    state = StreamJson.new()

    assert {:ok, [malformed], _state} = StreamJson.feed(state, "[1,2,3]\n")

    assert {:malformed, "[1,2,3]", {:non_object_root, [1, 2, 3]}} = malformed
  end

  test "skips blank lines silently" do
    state = StreamJson.new()
    input = ~s(\n\n{"keep":true}\n\n)

    assert {:ok, [%{"keep" => true}], _state} = StreamJson.feed(state, input)
  end

  test "supports CRLF line terminators" do
    state = StreamJson.new()
    input = ~s({"a":1}\r\n{"b":2}\r\n)

    assert {:ok, [%{"a" => 1}, %{"b" => 2}], _state} = StreamJson.feed(state, input)
  end

  test "flush returns no events when the buffer is empty" do
    state = StreamJson.new()

    assert {:ok, [], _state} = StreamJson.flush(state)
  end

  test "flush drains a trailing object that lacks a final newline" do
    state = StreamJson.new()

    assert {:ok, [], state} = StreamJson.feed(state, ~s({"final":true}))
    assert state.buffer == ~s({"final":true})

    assert {:ok, [%{"final" => true}], state} = StreamJson.flush(state)
    assert state.buffer == ""
  end

  test "flush surfaces malformed trailing bytes" do
    state = StreamJson.new()

    assert {:ok, [], state} = StreamJson.feed(state, "garbage tail")

    assert {:ok, [{:malformed, "garbage tail", _reason}], _state} = StreamJson.flush(state)
  end
end
