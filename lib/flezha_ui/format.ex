defmodule FlezhaUi.Format do
  @moduledoc """
  Rendering controller values as text.

  Deliberately free of any Phoenix dependency: the same rendering is wanted by
  a service preparing a message for broadcast and by a screen showing it, and a
  helper only the web layer could reach would be copied into the service.
  """

  @doc """
  A binary as something readable.

  Payloads are arbitrary bytes. Valid UTF-8 is shown as itself; anything else
  is hex, because a terminal-mangling byte sequence in a table cell helps
  nobody. `:limit` caps the result.
  """
  def printable(nil), do: "(none)"

  def printable(value, opts \\ [])

  def printable(value, opts) when is_binary(value) do
    limit = Keyword.get(opts, :limit)

    text = if String.valid?(value), do: value, else: Base.encode16(value, case: :lower)

    if limit, do: String.slice(text, 0, limit), else: text
  end

  def printable(value, _opts), do: inspect(value)

  @doc """
  A payload a relay emitted or ingested, as a listen screen shows it: printable
  text, its size, its metadata and when it arrived here.

  Sized before it is rendered printable: a non-UTF-8 payload becomes hex, which
  would report double what actually crossed the wire.
  """
  def frame(payload, metadata) do
    %{
      message: printable(payload),
      bytes: payload_bytes(payload),
      metadata: metadata || %{},
      timestamp: DateTime.utc_now()
    }
  end

  @doc "A payload's size as it crossed the wire: its bytes, or its external term's."
  def payload_bytes(payload) when is_binary(payload), do: byte_size(payload)
  def payload_bytes(payload), do: payload |> :erlang.term_to_binary() |> byte_size()

  @doc """
  A duration in milliseconds, to the two largest units that apply.

  For a figure the operator reads on its own — an uptime — where "3d 4h" says
  more than "3d".
  """
  def duration(nil), do: "—"

  def duration(ms) when is_integer(ms) and ms < 1_000, do: "#{ms}ms"

  def duration(ms) when is_integer(ms) do
    {days, hours, minutes, seconds} = split_duration(div(ms, 1_000))

    cond do
      days > 0 -> "#{days}d #{hours}h"
      hours > 0 -> "#{hours}h #{minutes}m"
      minutes > 0 -> "#{minutes}m #{seconds}s"
      true -> "#{seconds}s"
    end
  end

  def duration(_other), do: "—"

  @doc """
  A duration in seconds, to its largest unit alone.

  For a table column, where a compact cell reads better down a list than a
  precise one.
  """
  def age(nil), do: "—"

  def age(seconds) when is_integer(seconds) do
    {days, hours, minutes, _seconds} = split_duration(seconds)

    cond do
      days > 0 -> "#{days}d"
      hours > 0 -> "#{hours}h"
      minutes > 0 -> "#{minutes}m"
      true -> "#{seconds}s"
    end
  end

  def age(_other), do: "—"

  defp split_duration(seconds) do
    minutes = div(seconds, 60)
    hours = div(minutes, 60)
    days = div(hours, 24)

    {days, rem(hours, 24), rem(minutes, 60), rem(seconds, 60)}
  end

  @doc "A byte count at the largest unit that keeps it readable."
  def bytes(nil), do: "—"
  def bytes(bytes) when bytes < 1_024, do: "#{bytes} B"
  def bytes(bytes) when bytes < 1_048_576, do: "#{Float.round(bytes / 1_024, 1)} KB"
  def bytes(bytes), do: "#{Float.round(bytes / 1_048_576, 1)} MB"

  @doc "An absolute time, for a value an operator may compare against a clock."
  def timestamp(nil), do: "—"
  def timestamp(%DateTime{} = dt), do: Calendar.strftime(dt, "%Y-%m-%d %H:%M:%S %Z")
  def timestamp(other), do: to_string(other)

  @doc "A wall-clock time to the millisecond, for a live stream where only the time of day matters."
  def time_of_day(%DateTime{} = dt) do
    Calendar.strftime(dt, "%H:%M:%S.") <>
      (dt.microsecond
       |> elem(0)
       |> div(1_000)
       |> Integer.to_string()
       |> String.pad_leading(3, "0"))
  end

  def time_of_day(_other), do: "—"

  @doc """
  A token's `expires_at`, which the controller answers as unix seconds or the
  atom `:never`.
  """
  def token_expiry(:never), do: "never"
  def token_expiry(seconds) when is_integer(seconds), do: unix_time(seconds, :second)
  def token_expiry(_other), do: "—"

  @doc """
  A unix time the controller answers as an integer in `unit` — `:second` for a
  token or a drop mark, `:millisecond` for a shipment — as an absolute time.
  """
  def unix_time(value, unit) when is_integer(value) do
    case DateTime.from_unix(value, unit) do
      {:ok, dt} -> timestamp(dt)
      _ -> to_string(value)
    end
  end

  def unix_time(nil, _unit), do: "—"
  def unix_time(other, _unit), do: inspect(other)

  @doc "A partition's key groups, `{first, last}`, as `first–last`."
  def key_range({first, last}), do: "#{first}–#{last}"

  @doc "A snake_case controller id as a human-readable label."
  def humanize(id) do
    id
    |> to_string()
    |> String.replace("_", " ")
    |> String.split(" ")
    |> Enum.map_join(" ", &String.capitalize/1)
  end

  @doc "A module name as text, for a provider shown in a table."
  def module_name(nil), do: "—"
  def module_name(module), do: inspect(module)

  @doc "A record as one line of JSON, falling back to `inspect/1`."
  def json_line(record) when is_map(record) do
    Jason.encode!(record)
  rescue
    _ -> inspect(record)
  end

  def json_line(record), do: inspect(record)

  @doc "What an operator is told when `Relay.stop` answered for relay `id`."
  def relay_stopped(id, %{stopped: :cooperative}),
    do: "Relay #{id} is stopping: it finishes its in-flight work before it is removed."

  def relay_stopped(id, _answer), do: "Relay #{id} stopped."
end
