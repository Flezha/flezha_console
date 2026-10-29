defmodule FlezhaConsoleWeb.LogsLive do
  @moduledoc """
  Every durable log the controller keeps, one kind per tab: its files on each
  controller, filtered reads across the cluster, and a live tail.

  The kinds, their filters and their columns are what the controller
  declares, so a kind it adds later is listed here with no change. A kind
  `FlezhaConsoleWeb.LogLines` can say in words is read as sentences.

  The applied filters ride the address, so a filtered view can be linked to.
  The tail starts paused: a screen left open in a tab would otherwise hold a
  subscription on the controller for nobody's benefit.
  """

  use FlezhaConsoleWeb, :live_view
  use FlezhaConsoleWeb.Live.Tail, tag: :logs_tail, max: 200

  alias FlezhaConsole.Service.NodeManager
  alias FlezhaConsoleWeb.Live.Refresh
  alias FlezhaConsoleWeb.LogLines

  # Each Read more appends to what one screen holds, so it is capped.
  @max_records 5_000
  @default_limit 100
  @disabled_codes ~w(audit.disabled logs.kind_disabled observability.disabled)

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> Refresh.assign_token()
      |> init_tail()
      |> assign(
        page_title: "Logs",
        kind: nil,
        kinds: nil,
        kinds_error: nil,
        kinds_loading?: false,
        query: %{},
        filter: %{},
        records: nil,
        next: nil,
        read_error: nil,
        catalog_unreachable: [],
        read_unreachable: [],
        catalog: [],
        stats: [],
        load_error: nil,
        disabled: nil,
        rotate_error: nil,
        expanded: MapSet.new()
      )

    if connected?(socket) do
      token = socket.assigns.flezha_token

      {:ok,
       socket
       |> Refresh.on_answer(:kinds, :kinds_loading?, &kinds_answered/2)
       |> Refresh.start_once(:kinds_loading?, :kinds, fn -> NodeManager.log_kinds(token) end)}
    else
      {:ok, socket}
    end
  end

  @doc "A forwarded record is shown as the controller decoded it."
  @impl FlezhaConsoleWeb.Live.Tail
  def unwrap_tail(record), do: record

  # The kinds are read once, off the screen's process; the address is applied
  # once they are known, since they decide which filters it may carry.
  @impl true
  def handle_params(params, _uri, socket) do
    socket = assign(socket, :params, params)

    if socket.assigns.kinds, do: {:noreply, apply_params(socket)}, else: {:noreply, socket}
  end

  defp kinds_answered(socket, {:ok, {:ok, kinds}}) when is_list(kinds),
    do: socket |> assign(kinds: kinds, kinds_error: nil) |> apply_params()

  defp kinds_answered(socket, {:ok, {:error, reason}}),
    do: assign(socket, kinds: [], kinds_error: reason)

  defp kinds_answered(socket, _died), do: assign(socket, kinds: [], kinds_error: :read_failed)

  # `/logs` opens the first kind the controller lists.
  defp apply_params(%{assigns: %{params: params, kinds: kinds}} = socket)
       when not is_map_key(params, "kind") do
    case kinds do
      [first | _] -> push_patch(socket, to: ~p"/logs/#{first.id}", replace: true)
      [] -> socket
    end
  end

  defp apply_params(%{assigns: %{params: %{"kind" => kind} = params}} = socket) do
    declared = Enum.find(socket.assigns.kinds, &(&1.id == kind))
    query = query(params, declared)
    switched? = kind != socket.assigns.kind

    socket =
      socket
      |> assign(kind: kind, declared: declared, query: query, filter: query)
      |> assign(page_title: (declared && declared.title) || "Logs")

    cond do
      is_nil(declared) ->
        socket |> stop_tail() |> assign(records: nil, next: nil, catalog: [], stats: [])

      switched? ->
        socket |> stop_tail() |> assign(tail_records: []) |> load_catalog() |> read()

      true ->
        socket |> follow_filters() |> read()
    end
  end

  # A running tail follows the filters as they change.
  defp follow_filters(%{assigns: %{tailing: nil}} = socket), do: socket
  defp follow_filters(socket), do: open_tail(socket)

  @doc """
  The query an address carries for a kind: its declared filters, the time
  range, the limit and a file on a controller. Anything else is dropped, since
  the controller refuses a filter its kind does not declare.
  """
  def query(params, declared) do
    fields = if declared, do: Enum.map(declared.filters, & &1.field), else: []

    params
    |> Map.take(fields ++ ~w(since until limit file node))
    |> Map.reject(fn {_key, value} -> not is_binary(value) or String.trim(value) == "" end)
    |> Map.new(fn {key, value} -> {key, String.trim(value)} end)
  end

  @impl true
  def handle_event("filter_change", %{"filter" => params}, socket) when is_map(params) do
    {:noreply, assign(socket, filter: Map.merge(socket.assigns.filter, params))}
  end

  # Reading patches the address, which reads: the filtered view can then be
  # linked to and survives a reload. A new read starts from the newest file.
  def handle_event("read", params, %{assigns: %{declared: %{}}} = socket) do
    filter = Map.merge(socket.assigns.filter, params["filter"] || %{})

    {:noreply,
     push_patch(socket, to: logs_path(socket.assigns.kind, Map.drop(filter, ~w(file node))))}
  end

  def handle_event("read", _params, socket), do: {:noreply, socket}

  # A listed file opens into Records: the same filters, that file on that
  # controller. Only a file the listing holds is opened.
  def handle_event("open_file", %{"node" => node, "file" => file}, socket) do
    listed? = Enum.any?(socket.assigns.catalog, &(&1.node == node and &1.filename == file))

    if listed? and NodeManager.granted?(socket.assigns.operations, "Logs.read") do
      query = Map.merge(socket.assigns.query, %{"node" => node, "file" => file})

      {:noreply,
       socket |> push_patch(to: logs_path(socket.assigns.kind, query)) |> reveal("logs-records")}
    else
      {:noreply, socket}
    end
  end

  def handle_event("open_file", _params, socket), do: {:noreply, socket}

  def handle_event("read_more", _params, %{assigns: %{records: [_ | _], next: next}} = socket)
      when is_binary(next) do
    if more_readable?(socket.assigns.records),
      do: {:noreply, read(socket, next)},
      else: {:noreply, socket}
  end

  def handle_event("read_more", _params, socket), do: {:noreply, socket}

  def handle_event("record_toggle", %{"key" => key}, socket) when is_binary(key) do
    shown = (socket.assigns.records || []) ++ socket.assigns.tail_records

    if Enum.any?(shown, &(record_key(&1) == key)) do
      {:noreply, update(socket, :expanded, &toggle(&1, key))}
    else
      {:noreply, socket}
    end
  end

  def handle_event("record_toggle", _params, socket), do: {:noreply, socket}

  # Closes one controller's current file so it joins the listing; nothing is
  # lost, so it asks no confirmation. A refusal leaves the listing as it was.
  def handle_event("rotate", %{"node" => node}, socket) do
    if NodeManager.granted?(socket.assigns.operations, "Logs.rotate") and
         Enum.any?(socket.assigns.catalog, &(&1.node == node and &1.current?)) do
      {:noreply, rotate(socket, node)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("start_tail", _params, %{assigns: %{declared: %{}}} = socket),
    do: {:noreply, open_tail(socket)}

  def handle_event("start_tail", _params, socket), do: {:noreply, socket}

  def handle_event("stop_tail", _params, socket), do: {:noreply, stop_tail(socket)}

  @impl true
  def handle_info(_msg, socket), do: {:noreply, socket}

  defp open_tail(socket) do
    %{kind: kind, query: query, declared: declared, flezha_token: token} = socket.assigns
    filters = filters(query, declared)

    start_tail(socket, &NodeManager.log_tail(kind, filters, token, &1))
  end

  defp rotate(socket, node) do
    %{kind: kind, flezha_token: token} = socket.assigns

    case NodeManager.log_rotate(kind, node, token) do
      {:ok, %{rotated: [%{rotated_to: to} | _]}} when is_binary(to) ->
        socket
        |> assign(rotate_error: nil)
        |> load_catalog()
        |> put_flash(:info, "#{node} started a new file: the closed one is listed below.")

      {:ok, %{rotated: [%{error: error} | _]}} ->
        assign(socket, rotate_error: {:remote_error, error})

      {:ok, _none} ->
        assign(socket, rotate_error: {:controller_unreachable, node})

      {:error, reason} ->
        assign(socket, rotate_error: reason)
    end
  end

  # Files and statistics, one row set per controller. A refusal is not an
  # empty log, and a switched-off kind is a configuration, not a failure.
  defp load_catalog(socket) do
    %{kind: kind, flezha_token: token} = socket.assigns
    files = NodeManager.log_files(kind, token)
    stats = NodeManager.log_stats(kind, token)

    case {files, stats} do
      {{:ok, %{rows: files}}, {:ok, %{rows: stats}}} ->
        assign(socket,
          catalog: catalog(files, stats),
          stats: Enum.sort_by(stats, &to_string(&1.node)),
          load_error: nil,
          disabled: nil,
          catalog_unreachable: NodeManager.unreachable([{:ok, files}, {:ok, stats}])
        )

      {{:error, reason}, _} ->
        failed(socket, reason)

      {_, {:error, reason}} ->
        failed(socket, reason)
    end
  end

  defp failed(socket, reason) do
    socket = assign(socket, catalog: [], stats: [])

    if disabled?(reason),
      do: assign(socket, disabled: NodeManager.error(reason), load_error: nil),
      else: assign(socket, disabled: nil, load_error: reason)
  end

  defp disabled?(reason), do: NodeManager.error(reason).code in @disabled_codes

  # The file each controller is writing comes first, so every controller's
  # Rotate is on the first page; then the rotated ones, by controller, as each
  # lists them.
  defp catalog(files, stats) do
    current =
      for %{current_file: file} = row <- stats, is_binary(file) do
        %{
          node: to_string(row.node),
          filename: Path.basename(file),
          record_count: row[:record_count],
          size_bytes: row[:current_file_bytes],
          current?: true
        }
      end

    rotated = Enum.map(files, &Map.merge(&1, %{node: to_string(&1.node), current?: false}))

    (current ++ rotated)
    |> Enum.with_index()
    |> Enum.sort_by(fn {file, index} -> {not file.current?, file.node, index} end)
    |> Enum.map(&elem(&1, 0))
  end

  defp read(socket, before \\ nil) do
    %{kind: kind, query: query, declared: declared, flezha_token: token} = socket.assigns
    shown = if before, do: socket.assigns.records, else: []
    limit = min(limit(query), @max_records - length(shown))

    params =
      %{
        filters: filters(query, declared),
        limit: limit,
        before: before,
        since_us: time_us(query["since"]),
        until_us: time_us(query["until"])
      }
      |> then(
        &if query["file"],
          do: Map.merge(&1, %{file: query["file"], node: query["node"]}),
          else: &1
      )

    case NodeManager.log_read(kind, params, token) do
      {:ok, %{records: records} = answer} ->
        socket
        |> assign(
          records: shown ++ records,
          next: answer[:next],
          read_error: nil,
          read_unreachable: NodeManager.unreachable([{:ok, answer}])
        )
        |> then(&if before, do: &1, else: assign(&1, expanded: MapSet.new()))

      {:error, reason} when is_nil(before) ->
        if disabled?(reason),
          do:
            assign(socket,
              records: nil,
              next: nil,
              read_error: nil,
              disabled: NodeManager.error(reason)
            ),
          else: assign(socket, records: nil, next: nil, read_error: reason)

      {:error, reason} ->
        assign(socket, read_error: reason)
    end
  end

  @doc "Whether Read more may add to `records`, under the cap."
  def more_readable?(records), do: length(records) < @max_records

  @doc false
  def max_records, do: @max_records

  defp filters(query, declared) do
    for %{field: field} <- declared.filters, value = query[field], into: %{}, do: {field, value}
  end

  defp limit(query) do
    case Integer.parse(query["limit"] || "") do
      {n, ""} when n > 0 and n <= 1_000 -> n
      _ -> @default_limit
    end
  end

  # A time typed into the form is read as UTC.
  defp time_us(nil), do: nil

  defp time_us(text) do
    text = if String.length(text) == 16, do: text <> ":00", else: text

    case NaiveDateTime.from_iso8601(text) do
      {:ok, at} -> at |> DateTime.from_naive!("Etc/UTC") |> DateTime.to_unix(:microsecond)
      {:error, _} -> nil
    end
  end

  defp logs_path(kind, query) do
    case Map.reject(query, fn {_key, value} -> value in [nil, ""] end) do
      empty when map_size(empty) == 0 -> ~p"/logs/#{kind}"
      query -> ~p"/logs/#{kind}?#{query}"
    end
  end

  @doc "A record's key: what its expansion is remembered by."
  def record_key(record), do: record |> :erlang.phash2() |> Integer.to_string()

  defp toggle(set, key),
    do: if(MapSet.member?(set, key), do: MapSet.delete(set, key), else: MapSet.put(set, key))

  @doc "The tabs: one per kind the controller declares, the one shown marked."
  def kind_tabs(kinds, kind) do
    for %{id: id, title: title} <- kinds || [] do
      %{
        label: title,
        path: ~p"/logs/#{id}",
        current?: id == kind,
        testid: "logs-tab-#{id}",
        patch?: true
      }
    end
  end

  # The handful an operator reads at a glance, per controller.
  defp stat_tiles(stats) do
    [
      {"Records in the current file", stats[:record_count] || 0},
      {"Files", stats[:total_files] || 0},
      {"Size", Format.bytes(stats[:total_bytes] || 0)},
      {"Fsync", Words.humanize(stats[:fsync_mode])}
    ]
  end

  @doc """
  Records as rows, newest first: a kind the console says in words as its
  sentence, any other by the columns it declares. A row expands in place to
  the whole record.
  """
  attr :records, :list, required: true
  attr :kind, :string, required: true
  attr :declared, :map, required: true
  attr :expanded, :any, required: true
  attr :testid, :string, required: true

  def log_records(assigns) do
    sentences? = LogLines.sentence(assigns.kind, %{}) != nil
    # The time is the controller's wall-clock stamp, shown relative to now.
    columns = Enum.reject(assigns.declared.columns, &(&1.type == "time"))

    assigns =
      assign(assigns,
        sentences?: sentences?,
        columns: columns,
        heads: if(sentences?, do: ["Record", "Controller"], else: Enum.map(columns, & &1.label))
      )

    ~H"""
    <div
      class="fcon-record-head fcon-record-cols"
      style={"--fcon-record-cols: #{length(@heads)}"}
      aria-hidden="true"
    >
      <span>Time</span>
      <span :for={head <- @heads}>{head}</span>
    </div>
    <ol data-testid={@testid} class="fcon-records">
      <li :for={record <- @records} data-testid="log-record">
        <% key = record_key(record) %>
        <button
          type="button"
          class="fcon-record-head"
          style={"--fcon-record-cols: #{length(@heads)}"}
          aria-expanded={to_string(MapSet.member?(@expanded, key))}
          phx-click="record_toggle"
          phx-value-key={key}
          data-testid="log-record-head"
        >
          <.moment at={LogLines.time(record)} unit={:millisecond} />
          <%= if @sentences? do %>
            <LogLines.line line={LogLines.sentence(@kind, record)} testid="log-record-sentence" />
            <span class="fcon-num">{LogLines.cell(record, "node")}</span>
          <% else %>
            <span :for={column <- @columns}>{LogLines.cell(record, column.field)}</span>
          <% end %>
        </button>
        <pre
          :if={MapSet.member?(@expanded, key)}
          class="fcon-code"
          data-testid="log-record-json"
        >{Format.json_line(record, pretty: true)}</pre>
      </li>
    </ol>
    """
  end

  defp disabled_text(%{code: "observability.disabled"}),
    do:
      "Observability is off on the controller, which switches this log off with it. " <>
        "Enable it with FLEZHA_OBSERVABILITY_ENABLED=true."

  defp disabled_text(%{message: message}), do: Words.sentence_start(message) <> "."
end
