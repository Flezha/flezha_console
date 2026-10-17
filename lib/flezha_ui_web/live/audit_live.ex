defmodule FlezhaUiWeb.AuditLive do
  @moduledoc """
  The controller's durable audit log: its files, filtered reads, and a live tail.

  The tail starts paused. A screen left open in a tab would otherwise hold a
  subscription on the controller indefinitely for nobody's benefit.
  """

  use FlezhaUiWeb, :live_view
  use FlezhaUiWeb.Live.Tail, tag: :audit_tail, max: 200

  alias FlezhaUi.Service.NodeManager

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> FlezhaUiWeb.Live.Refresh.assign_token()
      |> init_tail()
      |> assign(
        page_title: "Audit log",
        filter: %{"file" => "", "source" => "", "name" => "", "limit" => "100"},
        records: nil,
        truncated: false,
        expanded: MapSet.new(),
        disabled_reason: nil,
        rotate_error: nil
      )
      |> load_catalog()

    {:ok, socket}
  end

  @doc "A forwarded audit record is shown as the controller decoded it."
  @impl FlezhaUiWeb.Live.Tail
  def unwrap_tail(record), do: record

  @impl true
  def handle_event("filter_change", %{"filter" => params}, socket) do
    {:noreply, assign(socket, filter: Map.merge(socket.assigns.filter, params))}
  end

  @impl true
  def handle_event("read", _params, socket), do: {:noreply, read(socket)}

  # A listed file opens into Records: the same read, with the file set and the
  # rest of the filter kept. Only a file the catalog lists is opened.
  @impl true
  def handle_event("open_file", %{"file" => file}, socket) when is_binary(file) do
    if NodeManager.granted?(socket.assigns.operations, "AuditLog.read") and
         file in Enum.map(socket.assigns.catalog, & &1.filename) do
      {:noreply,
       socket
       |> assign(filter: Map.put(socket.assigns.filter, "file", file))
       |> read()
       |> reveal("audit-records")}
    else
      {:noreply, socket}
    end
  end

  def handle_event("open_file", _params, socket), do: {:noreply, socket}

  # The next records of the same read, after the ones shown.
  @impl true
  def handle_event(
        "read_more",
        _params,
        %{assigns: %{records: [_ | _], truncated: true}} = socket
      ),
      do: {:noreply, read_more(socket)}

  def handle_event("read_more", _params, socket), do: {:noreply, socket}

  @impl true
  def handle_event("record_toggle", %{"index" => index}, socket) when is_binary(index) do
    count = length(socket.assigns.records || [])

    case Integer.parse(index) do
      {i, ""} when i >= 0 and i < count ->
        expanded = socket.assigns.expanded

        {:noreply,
         assign(socket,
           expanded:
             if(MapSet.member?(expanded, i),
               do: MapSet.delete(expanded, i),
               else: MapSet.put(expanded, i)
             )
         )}

      _forged ->
        {:noreply, socket}
    end
  end

  def handle_event("record_toggle", _params, socket), do: {:noreply, socket}

  # Closes the current file so it joins the catalog; nothing is lost, so it
  # asks no confirmation. A refusal leaves the catalog as it was.
  @impl true
  def handle_event("rotate", _params, socket) do
    case NodeManager.audit_rotate(socket.assigns.flezha_token) do
      {:ok, _rotated} ->
        {:noreply,
         socket
         |> assign(rotate_error: nil)
         |> load_catalog()
         |> put_flash(:info, "Audit log rotated: the closed file is listed below.")}

      {:error, reason} ->
        {:noreply, assign(socket, rotate_error: reason)}
    end
  end

  @impl true
  def handle_event("start_tail", _params, socket) do
    token = socket.assigns.flezha_token

    {:noreply, start_tail(socket, &NodeManager.audit_tail(token, &1))}
  end

  @impl true
  def handle_event("stop_tail", _params, socket) do
    {:noreply, stop_tail(socket)}
  end

  @impl true
  def handle_info(_msg, socket), do: {:noreply, socket}

  defp load_catalog(socket) do
    case NodeManager.audit_files(socket.assigns.flezha_token) do
      {:ok, files} when is_list(files) ->
        stats = NodeManager.ok_or(NodeManager.audit_stats(socket.assigns.flezha_token), nil)

        assign(socket,
          files: files,
          stats: stats,
          catalog: catalog(files, stats),
          load_error: nil,
          read_error: nil,
          disabled_reason: nil
        )

      # A refusal is not an empty log: the screen has to say a token is missing,
      # or the operator reads "nothing was audited" from "we were not allowed
      # to look". A switched-off subsystem is a configuration, not a failure.
      {:error, reason} ->
        disabled = NodeManager.error(reason).code

        if disabled in ~w(audit.disabled observability.disabled),
          do:
            assign(socket,
              files: [],
              stats: nil,
              catalog: [],
              load_error: nil,
              read_error: nil,
              disabled_reason: disabled
            ),
          else:
            assign(socket,
              files: [],
              stats: nil,
              catalog: [],
              load_error: reason,
              read_error: nil,
              disabled_reason: nil
            )
    end
  end

  # A read asks for one more than the limit: getting it back is how a cut-off
  # result is told from a short one. Read more reads the same file with the
  # same filter again and drops what is already shown: the file only grows,
  # and its records' timestamps are a VM's monotonic clock, which a
  # restarted controller does not carry on, so position is the only order.
  defp read(socket), do: read_from(assign(socket, read_filter: socket.assigns.filter), [])

  defp read_more(%{assigns: %{records: shown}} = socket), do: read_from(socket, shown)

  defp read_from(socket, shown) do
    filter = socket.assigns.read_filter
    limit = parse_limit(filter["limit"])
    params = read_params(filter, length(shown) + limit + 1)

    case NodeManager.audit_read(params, socket.assigns.flezha_token) do
      {:ok, records} when is_list(records) ->
        next = Enum.drop(records, length(shown))

        socket
        |> assign(
          records: shown ++ Enum.take(next, limit),
          truncated: length(next) > limit,
          read_error: nil
        )
        |> then(&if(shown == [], do: assign(&1, expanded: MapSet.new()), else: &1))

      {:error, reason} when shown == [] ->
        assign(socket, records: nil, truncated: false, read_error: reason)

      {:error, reason} ->
        assign(socket, read_error: reason)
    end
  end

  # The catalog as listed: the file being written first, then the rotated
  # files the controller reports.
  defp catalog(files, stats) do
    current =
      case stats do
        # The statistics name it by its path; a read names a file of the
        # audit directory by its name alone.
        %{current_file: file} when is_binary(file) ->
          [
            %{
              filename: Path.basename(file),
              record_count: stats[:record_count],
              size_bytes: stats[:current_file_bytes],
              current?: true
            }
          ]

        _none ->
          []
      end

    current ++ Enum.map(files, &Map.put(&1, :current?, false))
  end

  @doc """
  A field of an audit record, by its path: records arrive keyed by string, as
  the controller decoded them from JSON.
  """
  def field(record, path) do
    Enum.reduce_while(path, record, fn
      key, %{} = map -> {:cont, Map.get(map, key)}
      _key, _leaf -> {:halt, nil}
    end)
  end

  @doc """
  What came of the audited act: its outcome, else the error it answered, else
  why it was refused; nil when the record states none.
  """
  def outcome(record) do
    field(record, ["metadata", "outcome"]) || field(record, ["metadata", "error_code"]) ||
      field(record, ["metadata", "reason"])
  end

  defp read_params(filter, limit) do
    %{limit: limit}
    |> put_present(:file, filter["file"])
    |> put_present(:source, filter["source"])
    |> put_present(:name, filter["name"])
  end

  defp put_present(params, _key, value) when value in [nil, ""], do: params
  defp put_present(params, key, value), do: Map.put(params, key, value)

  defp parse_limit(value) do
    case Integer.parse(to_string(value)) do
      {n, ""} when n > 0 and n <= 1_000 -> n
      _ -> 100
    end
  end

  defp disabled_message("audit.disabled") do
    "Audit logging is off on the controller. Enable it with FLEZHA_AUDIT_ENABLED=true."
  end

  defp disabled_message("observability.disabled") do
    "Observability is off on the controller, which disables the audit log with it. " <>
      "Enable it with FLEZHA_OBSERVABILITY_ENABLED=true."
  end

  defp current_file(%{current_file: file}) when is_binary(file), do: file
  defp current_file(_), do: "the current audit file"

  # The handful an operator reads at a glance; the rest of the writer's stats
  # are in the record stream itself.
  defp stat_tiles(stats) when is_map(stats) do
    [
      {"Records", stats[:record_count] || 0},
      {"Files", stats[:total_files] || 0},
      {"Size", FlezhaUi.Format.bytes(stats[:total_bytes] || 0)},
      {"Fsync", Words.humanize(stats[:fsync_mode])}
    ]
  end

  defp stat_tiles(_), do: []
end
