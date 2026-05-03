defmodule SymphonyElixir.Claude.StreamJson do
  @moduledoc """
  Buffered NDJSON line parser for `claude --output-format stream-json`.

  Claude Code emits one JSON object per line on stdout. This module collects
  partial reads (Port chunks may split or merge lines) and yields fully-decoded
  maps in arrival order.
  """

  @type t :: %__MODULE__{buffer: binary()}
  defstruct buffer: ""

  @spec new() :: t()
  def new, do: %__MODULE__{}

  @doc """
  Append a chunk to the buffer and return `{:ok, [parsed_object], updated}`.

  Lines that fail JSON decoding are returned as `{:malformed, raw_line, reason}`
  tuples in the same order so callers can decide whether to log or terminate.
  """
  @spec feed(t(), binary()) ::
          {:ok, [map() | {:malformed, binary(), term()}], t()}
  def feed(%__MODULE__{buffer: buffer} = state, chunk) when is_binary(chunk) do
    combined = buffer <> chunk
    {complete, leftover} = split_lines(combined)

    parsed =
      Enum.map(complete, fn line ->
        case Jason.decode(line) do
          {:ok, %{} = obj} -> obj
          {:ok, other} -> {:malformed, line, {:non_object_root, other}}
          {:error, reason} -> {:malformed, line, reason}
        end
      end)

    {:ok, parsed, %__MODULE__{state | buffer: leftover}}
  end

  @doc """
  Drain the trailing buffer when the producer closes the stream. The remainder
  is decoded if it is non-empty; otherwise this is a no-op.
  """
  @spec flush(t()) :: {:ok, [map() | {:malformed, binary(), term()}], t()}
  def flush(%__MODULE__{buffer: ""} = state), do: {:ok, [], state}

  def flush(%__MODULE__{buffer: buffer}) do
    parsed =
      case Jason.decode(buffer) do
        {:ok, %{} = obj} -> [obj]
        {:ok, other} -> [{:malformed, buffer, {:non_object_root, other}}]
        {:error, reason} -> [{:malformed, buffer, reason}]
      end

    {:ok, parsed, %__MODULE__{}}
  end

  defp split_lines(binary) do
    parts = :binary.split(binary, ["\n", "\r\n"], [:global])
    {complete, [tail]} = Enum.split(parts, length(parts) - 1)

    complete =
      complete
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    {complete, tail}
  end
end
