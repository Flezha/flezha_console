defmodule FlezhaUi.Service.EventRelay do
  @moduledoc """
  The loop that runs **on the flezha controller node** and forwards what it
  receives back to this UI.

  Serves every controller subscription whose API registers the *calling*
  process — `Flezha.Service.EventManager.add_handler/1` is `pg:join(scope,
  event, self())` and `pg` refuses a non-local pid; `Flezha.Service.AuditLog.
  tail/2` registers `self()` the same way. So the subscriber has to be a
  process living on the controller — an `:erpc` call cannot be one, because the
  process it runs in dies as soon as the call returns.

  This module's *source* is shipped to the controller and compiled there by
  `FlezhaUi.Service.EventBridge`, which then spawns `start/3`. Source rather
  than a compiled beam so the two nodes need not share an Erlang/OTP release.

  Everything it references must therefore exist on the controller: OTP, and
  `Flezha.*`. It must not reference any other `FlezhaUi.*` module, and it must
  not capture a closure defined elsewhere in this application — an anonymous
  function carries its defining module, which the controller does not have.

  It also must not read its own source: when this file is compiled on the
  controller there is no file behind it. `EventBridge` holds the source
  instead, which is why it and not this module owns the shipping.
  """

  @doc """
  Subscribes as described by `subscription`, then forwards everything received
  to `owner` as `{:relay_event, tag, message}` until `owner` dies.

  Runs on the controller. Unsubscribes on the way out, so a relay that is
  killed leaves no registration behind.

  `subscription` is one of:

    * `{:events, [event]}` — the controller's event bus.
    * `{:audit_tail, params}` — the durable audit log's live tail.
  """
  def start(owner, subscription, tag) when is_pid(owner) do
    handle = subscribe(subscription)
    ref = Process.monitor(owner)

    try do
      loop(owner, tag, ref)
    after
      unsubscribe(subscription, handle)
    end
  end

  defp subscribe({:events, events}) do
    Enum.each(events, &Flezha.Service.EventManager.add_handler/1)
    :ok
  end

  defp subscribe({:audit_tail, params}) do
    case Flezha.Service.AuditLog.tail(params, %{source: :ui}) do
      {:ok, tail_ref} -> tail_ref
      other -> other
    end
  end

  defp unsubscribe({:events, events}, _handle) do
    Enum.each(events, &Flezha.Service.EventManager.rem_handler/1)
  end

  defp unsubscribe({:audit_tail, _params}, tail_ref) when is_reference(tail_ref) do
    Flezha.Service.AuditLog.unsubscribe(tail_ref, %{source: :ui})
  end

  defp unsubscribe(_subscription, _handle), do: :ok

  defp loop(owner, tag, ref) do
    receive do
      {:DOWN, ^ref, :process, ^owner, _reason} ->
        :ok

      message ->
        send(owner, {:relay_event, tag, message})
        loop(owner, tag, ref)
    end
  end
end
