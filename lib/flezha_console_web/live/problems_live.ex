defmodule FlezhaConsoleWeb.ProblemsLive do
  @moduledoc """
  Every open problem in the namespaces the operator's token reaches, worst
  first and then the longest seen, each with what is wrong, why, and the
  action that fixes it.

  The screen reads the shell's pulse rather than reading anything itself, so
  the header's count and this list are one answer: a problem that clears
  leaves both on the same pulse, without a reload. The list shows a page at a
  time, and growing a namespace's item that says how many more relays are not
  healthy reads more of them on a pulse at once.
  """

  use FlezhaConsoleWeb, :live_view
  use FlezhaConsoleWeb.Attention

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> FlezhaConsoleWeb.Live.Refresh.assign_token()
     |> attention_init()
     |> assign(page_title: "Open problems")}
  end

  @doc false
  def listing_grown(socket, "problems-" <> _namespace), do: Layouts.pulse_now(socket)
  def listing_grown(socket, _id), do: socket

  @impl true
  def render(assigns) do
    ~H"""
    <.page_header eyebrow="Problems" title="Open problems">
      <:sentence>
        <%= cond do %>
          <% is_nil(@shell_pulse) -> %>
            Checking every namespace you can reach…
          <% @shell_pulse.error -> %>
            The
            <.term key="namespace">namespaces</.term>
            you can reach could not be checked.
          <% @shell_pulse.items == [] -> %>
            Nothing needs attention in any <.term key="namespace" /> you can reach.
          <% true -> %>
            {Words.count(length(@shell_pulse.items), "problem")} across the
            <.term key="namespace">namespaces</.term>
            you can reach, worst first.
        <% end %>
      </:sentence>
      <:figures :if={@shell_pulse}>
        Last checked at {Format.time_of_day(@shell_pulse.checked_at)}; checked again every 10 seconds.
      </:figures>
    </.page_header>

    <.skeleton :if={is_nil(@shell_pulse)} testid="problems-loading" />

    <.runtime_error :if={@shell_pulse} error={@shell_pulse.error} action="list the namespaces" />

    <.partial_answer
      :if={@shell_pulse}
      unreachable={@shell_pulse.unreachable}
      controllers={@shell_pulse.controllers}
    />

    <.partial_empty
      :if={
        @shell_pulse && is_nil(@shell_pulse.error) && @shell_pulse.items == [] &&
          @shell_pulse.unreachable != []
      }
      noun="problem"
    />

    <.empty_state
      :if={
        @shell_pulse && is_nil(@shell_pulse.error) && @shell_pulse.items == [] &&
          @shell_pulse.unreachable == []
      }
      icon="hero-check-circle"
      testid="problems-clear"
    >
      All clear: no relay, partition group, quota or dead-letter queue needs anything from you.
    </.empty_state>

    <.problem_list
      :if={@shell_pulse && @shell_pulse.items != []}
      items={@shell_pulse.items}
      operations={@operations}
      diagnoses={@diagnoses}
      paging={@paging}
      now={@shell_pulse.checked_at}
    />
    """
  end
end
