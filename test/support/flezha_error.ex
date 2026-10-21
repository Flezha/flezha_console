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
    "plugin.option_invalid" => :invalid,
    "plugin.option_above_maximum" => :invalid,
    "plugin.option_below_minimum" => :invalid,
    "plugin.options_required" => :invalid,
    "plugin.url_scheme_unsupported" => :invalid,
    "plugin.option_requires" => :invalid,
    "schedule.invalid_timezone" => :invalid,
    "schedule.already_exists" => :conflict,
    "observability.disabled" => :unavailable,
    "observability.pubsub_disabled" => :unavailable,
    "audit.disabled" => :unavailable,
    "controller.timeout" => :unavailable,
    "internal.uncatalogued" => :internal,
    "control.unknown_function" => :not_found,
    "diagnose.no_runner" => :unavailable,
    "diagnose.finished" => :conflict,
    "diagnose.unknown" => :unavailable,
    "api.channel_unknown" => :not_found,
    "api.not_advertised" => :unavailable,
    "call.timeout" => :unavailable,
    "call.busy" => :unavailable,
    "call.absorbed" => :conflict,
    "call.unavailable" => :unavailable,
    "usage.invalid_number" => :invalid,
    "authz.unknown_role" => :invalid,
    "plugin.package_invalid" => :invalid,
    "schedule.not_found" => :not_found,
    "state.inbox_unreadable" => :unavailable,
    "audit.writer_unavailable" => :unavailable,
    "runner.dropped" => :denied,
    "runner.not_found" => :not_found,
    "runner.untrackable" => :invalid
  }

  @doc "Every code the fake answers, with its class."
  def classes, do: @classes

  @doc """
  An error for `code`, with the class the catalogue gives it and its `details`
  keyed by text, as core keeps them.
  """
  def new(code, message \\ nil, hint \\ nil, details \\ %{}) do
    class = Map.fetch!(@classes, code)

    %__MODULE__{
      code: code,
      class: class,
      message: message || "#{code} (test)",
      hint: hint,
      details: details
    }
  end
end
