defmodule FlezhaUi.FormatTest do
  @moduledoc """
  The rendering both the service and the web layer share.

  Payload rendering matters beyond looks: a raw byte sequence dropped into a
  table cell can carry terminal escapes, so the hex fallback is a property
  worth pinning rather than a nicety.
  """

  use ExUnit.Case, async: true

  alias FlezhaUi.Format

  describe "printable/2" do
    test "shows valid UTF-8 as itself" do
      assert "store_1 ping" = Format.printable("store_1 ping")
    end

    test "shows bytes that are not text as hex" do
      assert "ff00fe" = Format.printable(<<255, 0, 254>>)
    end

    test "truncates to a limit when given one" do
      assert "abc" = Format.printable("abcdef", limit: 3)
    end

    test "renders a non-binary rather than raising" do
      assert "%{a: 1}" = Format.printable(%{a: 1})
    end

    test "says so when there is nothing" do
      assert "(none)" = Format.printable(nil)
    end
  end

  describe "frame/2" do
    test "sizes the payload before rendering it printable" do
      frame = Format.frame(<<255, 0, 254>>, %{"flz.seq" => 1})

      assert frame.message == "ff00fe"
      assert frame.bytes == 3
      assert frame.metadata == %{"flz.seq" => 1}
      assert %DateTime{} = frame.timestamp
    end

    test "a missing metadata map is an empty one" do
      assert %{message: "hi", bytes: 2, metadata: %{}} = Format.frame("hi", nil)
    end
  end

  describe "duration/1" do
    test "sub-second is reported in milliseconds" do
      assert "250ms" = Format.duration(250)
    end

    test "carries the two largest units that apply" do
      assert "45s" = Format.duration(45_000)
      assert "1m 32s" = Format.duration(92_000)
      assert "2h 5m" = Format.duration((2 * 3600 + 5 * 60) * 1000)
      assert "3d 4h" = Format.duration((3 * 86_400 + 4 * 3600) * 1000)
    end

    test "an absent duration renders as a dash, not a zero" do
      assert "—" = Format.duration(nil)
    end
  end

  describe "age/1" do
    test "carries only the largest unit, for a table column" do
      assert "45s" = Format.age(45)
      assert "5m" = Format.age(320)
      assert "2h" = Format.age(7_500)
      assert "3d" = Format.age(300_000)
    end

    test "an absent age renders as a dash" do
      assert "—" = Format.age(nil)
    end
  end

  describe "bytes/1" do
    test "steps up units as the count grows" do
      assert "512 B" = Format.bytes(512)
      assert "1.0 KB" = Format.bytes(1_024)
      assert "1.5 MB" = Format.bytes(1_572_864)
      assert "100.0 GB" = Format.bytes(107_374_182_400)
    end
  end

  describe "key_range/1" do
    test "shows a partition's first and last key group" do
      assert Format.key_range({64, 127}) == "64–127"
    end
  end

  describe "humanize/1" do
    test "renders a controller id as a label" do
      assert "Relay WebSocket" = Format.humanize("relay_websocket")
      assert "Store Input" = Format.humanize("store_input")
    end

    test "spells acronyms the way readers know them" do
      assert "HTTP API" = Format.humanize("http_api")
      assert "Monitored IO Forward" = Format.humanize("monitored_io_forward")
      assert "Relay BEAM Msg" = Format.humanize("relay_beam_msg")
    end

    test "accepts an atom field name" do
      assert "Post Connect" = Format.humanize(:post_connect)
    end
  end

  describe "command/1" do
    test "quotes only the words a shell would split or expand" do
      assert Format.command(["flz", "relay", "start", "echo", "--init-values", ~s({"a": 1})]) ==
               ~s(flz relay start echo --init-values '{"a": 1}')

      assert Format.command(["it's", ""]) == ~S('it'"'"'s' '')
    end

    test "joins a word's parts, quoting each alone, and puts a raw part in as written" do
      assert Format.command([["--Xurl=", "http://h.test/x?a=1"]]) ==
               "--Xurl='http://h.test/x?a=1'"

      assert Format.command([["--Xkey=", {:raw, ~s("$KEY")}]]) == ~s(--Xkey="$KEY")
    end
  end

  describe "timestamp/1 and time_of_day/1" do
    test "an absolute time carries the date" do
      {:ok, dt, _} = DateTime.from_iso8601("2026-08-14T17:40:00Z")
      assert Format.timestamp(dt) =~ "2026-08-14 17:40:00"
    end

    test "a live feed's time carries only the time of day" do
      {:ok, dt, _} = DateTime.from_iso8601("2026-08-14T17:40:00.123456Z")
      assert Format.time_of_day(dt) =~ "17:40:00."
    end

    test "the time of day is to the millisecond, whatever the time's precision" do
      assert "05:20:00.042" =
               Format.time_of_day(DateTime.from_unix!(1_760_073_600_042, :millisecond))

      assert "05:20:00.000" = Format.time_of_day(DateTime.from_unix!(1_760_073_600))

      assert "05:20:00.123" =
               Format.time_of_day(DateTime.from_unix!(1_760_073_600_123_456, :microsecond))
    end

    test "an absent time renders as a dash" do
      assert "—" = Format.timestamp(nil)
      assert "—" = Format.time_of_day(nil)
    end
  end

  describe "json_line/1" do
    test "renders a map as one line of JSON" do
      assert ~s({"name":"read"}) = Format.json_line(%{"name" => "read"})
    end

    test "falls back to inspect for a term JSON cannot carry" do
      assert Format.json_line(%{ref: make_ref()}) =~ "#Reference<"
    end
  end

  describe "module_name/1" do
    test "renders a provider module as text" do
      assert "FlezhaUi.Format" = Format.module_name(FlezhaUi.Format)
    end

    test "an absent provider renders as a dash" do
      assert "—" = Format.module_name(nil)
    end
  end

  describe "unix_time/2" do
    test "reads seconds and milliseconds as the same absolute time" do
      assert Format.unix_time(1_760_000_000, :second) == "2025-10-09 08:53:20 UTC"
      assert Format.unix_time(1_760_000_000_000, :millisecond) == "2025-10-09 08:53:20 UTC"
    end

    test "an absent time is a dash, and a token that never expires says so" do
      assert Format.unix_time(nil, :second) == "—"
      assert Format.token_expiry(:never) == "never"
      assert Format.token_expiry(1_760_000_000) == "2025-10-09 08:53:20 UTC"
    end
  end
end
