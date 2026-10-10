defmodule Flezha.Error do
  @moduledoc """
  Test-only stand-in for the controller's error struct, with its fields.

  `lib/` never names it — the UI reads a controller error by its fields — so it
  exists only for fixtures to answer the shape a published function answers.
  Each code carries the class core's catalogue (`flz_transport/errors.json`)
  gives it, so a fixture cannot invent a class the controller would not send.
  """

  defstruct [:code, :class, :message, details: %{}, hint: nil]

  @classes %{
    "authz.principal_not_bound" => :denied,
    "authz.no_role_binding" => :denied,
    "authz.role_insufficient" => :denied,
    "authz.namespace_mismatch" => :denied,
    "authz.token_malformed" => :invalid,
    "authz.token_unknown" => :denied,
    "authz.token_revoked" => :denied,
    "authz.token_expired" => :denied,
    "authz.registry_unavailable" => :unavailable,
    "relay.not_found" => :not_found,
    "relay.not_running" => :unavailable,
    "relay.factory_not_steps" => :invalid,
    "relay.outside_retention" => :invalid,
    "relay.iteration_not_committed" => :invalid,
    "state.persistence_off" => :conflict,
    "state.not_resident" => :unavailable,
    "dlq.not_found" => :not_found,
    "dlq.payload_not_replayable" => :conflict,
    "namespace.already_exists" => :conflict,
    "namespace.invalid_name" => :invalid,
    "namespace.not_found" => :not_found,
    "plugin.not_found" => :not_found,
    "plugin.id_taken" => :conflict,
    "plugin.unknown_options" => :invalid,
    "plugin.init_after_start" => :invalid,
    "schedule.invalid_timezone" => :invalid,
    "schedule.already_exists" => :conflict,
    "observability.disabled" => :unavailable,
    "observability.pubsub_disabled" => :unavailable,
    "audit.disabled" => :unavailable,
    "controller.timeout" => :unavailable,
    "internal.uncatalogued" => :internal,
    "diagnose.no_runner" => :unavailable,
    "diagnose.finished" => :conflict,
    "diagnose.unknown" => :unavailable,
    "api.channel_unknown" => :not_found,
    "api.not_advertised" => :unavailable,
    "call.timeout" => :unavailable,
    "usage.invalid_number" => :invalid,
    "authz.unknown_role" => :invalid,
    "authz.bootstrap_token_mismatch" => :denied,
    "plugin.package_invalid" => :invalid,
    "schedule.not_found" => :not_found,
    "state.inbox_unreadable" => :unavailable,
    "audit.writer_unavailable" => :unavailable,
    "runner.dropped" => :denied,
    "runner.not_found" => :not_found,
    "runner.untrackable" => :invalid
  }

  @doc "An error for `code`, with the class the catalogue gives it."
  def new(code, message \\ nil, hint \\ nil) do
    class = Map.fetch!(@classes, code)
    %__MODULE__{code: code, class: class, message: message || "#{code} (test)", hint: hint}
  end
end
