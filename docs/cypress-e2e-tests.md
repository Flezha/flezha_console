# Cypress E2E Tests for Plugin Attachment

## Overview

Automated end-to-end tests that verify all available plugin providers can be attached to and detached from a processor via the UI. Tests run against the live app at `localhost:4000`.

## Prerequisites

- Docker stack running: `docker compose -f docker-compose.dev.yml up`
- Agent connected (check: `docker logs fui_web 2>&1 | grep NodeConnector`)
- Dev user seeded (`dev@flezha.local` / `dev_password_123`)
- At least one processor running in the `default` namespace (e.g., `testnet_store_1`)
- Node.js installed

## Setup

```bash
cd /home/moon/Code/flezha_ui
npm install
npx cypress verify
```

## Running Tests

```bash
# Headless (CI-friendly)
npm run cy:run

# Headed (watch in browser)
npm run cy:run:headed

# Interactive Cypress UI
npm run cy:open
```

## Test Spec: `cypress/e2e/plugin-attach.cy.ts`

### Test 1: "discovers all available providers"

Opens the attach modal, reads all providers from the provider grid, logs them, and verifies at least one exists.

### Test 2: "attaches and detaches each provider"

For each discovered provider:
1. Records existing binding IDs before attach
2. Opens the attach modal and selects the provider
3. Reads the server-generated plugin ID (avoids LiveView form race conditions)
4. Fills in position, trigger, and dynamic provider-specific fields using heuristic values
5. Submits the form
6. Checks outcome:
   - **Success**: modal closes, new binding row appears in table. Then detaches the plugin, verifies row removal, and confirms binding count returns to original.
   - **Failure**: modal stays open with error banner. Logs the error and continues to the next provider.
7. Prints a per-provider summary table to the terminal

At least one provider must fully pass (attach + detach) for the test to succeed. Any detach failure causes a hard test failure.

### Test 3: "attaches and detaches websocket plugin specifically"

Explicitly tests the websocket provider end-to-end:
1. Attaches a websocket plugin with `uri: ws://localhost:9999/test`
2. Verifies exactly 1 new binding row appears
3. Verifies the row contains "Websocket" as provider
4. Detaches the plugin
5. Verifies the binding row is removed and count is restored

## Verified Results (as of 2026-03-18)

| Provider | Attach | Detach | Notes |
|----------|--------|--------|-------|
| processor_io_filter | PASS | PASS | |
| processor_kafka_producer | FAIL | skipped | No Kafka broker in Docker stack — expected |
| processor_stdout | PASS | PASS | |
| processor_websocket | PASS | PASS | Also verified by dedicated test |

## Field Value Heuristics

Dynamic provider fields are filled based on field name patterns:

| Pattern             | Value                       |
|---------------------|-----------------------------|
| inverted/enabled    | `false`                     |
| metadata            | `{}`                        |
| opts/options        | `[]`                        |
| uri / url           | `ws://localhost:9999/test`  |
| hosts               | `localhost:9092`            |
| host                | `localhost`                 |
| port                | `9999`                      |
| pattern / regex     | `.*`                        |
| topic               | `test-topic`                |
| partition           | `0`                         |
| ack                 | `1`                         |
| interval / timeout  | `5000`                      |
| (default)           | `test_value_123`            |

## Custom Cypress Commands

Defined in `cypress/support/commands.ts`:

- **`cy.login()`** - Logs in as the dev user using session caching (only authenticates once per test run)
- **`cy.waitForLiveView()`** - Waits for the Phoenix LiveView WebSocket connection to be established and the page to finish loading

## data-testid Attributes

Added to `processor_live.html.heex` for test targeting (no logic changes):

| Element                      | data-testid                    |
|------------------------------|--------------------------------|
| Attach Plugin button         | `attach-plugin-btn`            |
| Bindings table               | `bindings-table`               |
| Each binding row             | `binding-row-{plugin_id}`      |
| Detach button per row        | `detach-btn-{plugin_id}`       |
| No plugins message           | `no-plugins-msg`               |
| Attach modal container       | `attach-modal`                 |
| Provider grid                | `provider-grid`                |
| Each provider button         | `provider-btn-{provider_id}`   |
| Plugin ID input              | `input-plugin-id`              |
| Position input               | `input-position`               |
| Trigger select               | `input-trigger`                |
| Dynamic field inputs         | `input-field-{field_name}`     |
| Cancel button (form)         | `attach-cancel-btn`            |
| Attach submit button         | `attach-submit-btn`            |
| Attach error banner          | `attach-error`                 |
| Detach confirm modal         | `detach-confirm-modal`         |
| Detach confirm button        | `detach-confirm-btn`           |
| Detach cancel button         | `detach-cancel-btn`            |

## Bug Fixes Included

Three bugs were found and fixed during E2E test development:

### 1. `erpc_call` didn't catch `:exit` signals (`node_manager.ex`)

The `erpc_call` function only caught `:error` but not `:exit`. When a remote GenServer crashed during a call, the exit signal propagated through ERPC and crashed the LiveView process, causing silent failures (modal would disappear without any error message).

**Fix**: Added `catch :exit, reason -> {:error, reason}` to `erpc_call`.

### 2. `enable_plugin` sent plain map instead of struct (`node_manager.ex` + `processor_live.ex`)

The agent's `PluginManager` expects a `Flezha.Plugin.Driver.IOBindingPlugin` struct wrapping a provider struct (e.g., `Flezha.Plugin.Provider.Websocket`). The UI was sending a plain atom-key map, causing `KeyError: key :__struct__ not found`.

**Fix**: `NodeManager.enable_plugin` now performs a 3-step build process via ERPC:
1. Calls `provider_module.build(settings)` on the agent to create the provider struct
2. Calls `IOBindingPlugin.build(common_params, provider_struct)` to create the plugin struct
3. Calls `PluginManager.enable_plugin(plugin_id, plugin_struct)` with the proper struct

Also added a nil guard: `enable_plugin(_, nil, _, _)` returns `{:error, "provider not found"}`.

### 3. Detach failed with "plugin not found" after PluginManager crash (`processor_live.ex` + `node_manager.ex`)

The agent's `PluginManager` GenServer keeps plugin registrations in memory. When it crashes (e.g., from bug #2), its supervisor restarts it with a **fresh empty state** — all registrations are lost. Plugins still appear in the UI (from the processor's overwatch state) but detach fails because the PluginManager has no record of them.

**Fix**: The `detach_plugin` handler now falls back to `IOBindingPlugin.disable(plugin_id, {namespace, processor_id})` when the PluginManager returns "plugin not found". This bypasses the PluginManager and removes the binding directly from the processor.

## File Structure

```
cypress/
  e2e/
    plugin-attach.cy.ts       # Main test spec
  support/
    e2e.ts                    # Global setup
    commands.ts               # Custom commands (login, waitForLiveView)
  fixtures/                   # (empty)
  screenshots/                # Auto-generated on failure (gitignored)
cypress.config.ts             # Cypress configuration
package.json                  # npm dependencies
tsconfig.json                 # TypeScript config for Cypress
```
