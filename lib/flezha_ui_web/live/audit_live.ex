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
  def handle_event("read", _params, socket) do
    limit = parse_limit(socket.assigns.filter["limit"])

    # Ask for one more than requested: getting it back is how we know the
    # result was cut off rather than simply short.
    params = read_params(socket.assigns.filter, limit + 1)

    case NodeManager.audit_read(params, socket.assigns.flezha_token) do
      {:ok, records} when is_list(records) ->
        {:noreply,
         assign(socket,
           records: Enum.take(records, limit),
           truncated: length(records) > limit,
           read_error: nil
         )}

      {:error, reason} ->
        {:noreply, assign(socket, records: nil, truncated: false, read_error: reason)}
    end
  end

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
        assign(socket,
          files: files,
          stats: NodeManager.ok_or(NodeManager.audit_stats(socket.assigns.flezha_token), nil),
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
              load_error: nil,
              read_error: nil,
              disabled_reason: disabled
            ),
          else:
            assign(socket,
              files: [],
              stats: nil,
              load_error: reason,
              read_error: nil,
              disabled_reason: nil
            )
    end
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
      {"Fsync", inspect(stats[:fsync_mode] || :unknown)}
    ]
  end

  defp stat_tiles(_), do: []
end
