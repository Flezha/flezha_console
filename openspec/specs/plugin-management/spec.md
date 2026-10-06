# plugin-management Specification

## Purpose
TBD - created by archiving change resync-with-flezha-runtime. Update Purpose after archive.
## Requirements
### Requirement: Provider discovery

The UI SHALL populate the provider selector from the controller at runtime using `Flezha.Service.Fleet.providers/1`, and SHALL NOT hard-code a provider list. Because the controller describes a provider's options only in its help text, the form SHALL take the provider's options as one JSON object and SHALL show the provider's help beside it.

#### Scenario: Providers are available on the controller

- **WHEN** an operator opens the plugin form
- **THEN** the selectable providers are exactly those `Service.Fleet.providers/1` reports, each by its id

#### Scenario: Entering a provider's options

- **WHEN** an operator has selected a provider
- **THEN** the form offers one JSON field for the provider's options
- **AND** options that are not a JSON object are reported on the form without a call being made

### Requirement: Plugin listing

The UI SHALL list enabled plugins from `Flezha.Service.PluginManager.enabled/2`, one call per namespace the bound token can reach, showing each plugin's name, provider, namespace, the relays bound to it, and its hooks. The same LiveView SHALL additionally serve a namespace-scoped listing at `/namespaces/:ns/plugins`, which reads that namespace alone: the controller answers the plugins of one namespace, so the scope is applied by the controller rather than by filtering a full listing.

#### Scenario: Plugins are enabled

- **WHEN** an operator opens the plugins screen
- **THEN** each enabled plugin is listed with its provider, its namespace, and the relays bound to it

#### Scenario: A namespace's own plugins

- **WHEN** an operator opens `/namespaces/:ns/plugins`
- **THEN** only the plugins enabled in that namespace are listed
- **AND** the listing is read with one `Service.PluginManager.enabled/2` call for that namespace

#### Scenario: One LiveView serves both routes

- **WHEN** the codebase is inspected
- **THEN** `/plugins` and `/namespaces/:ns/plugins` are served by the same LiveView module

#### Scenario: A plugin is bound to no relay

- **WHEN** a listed plugin has no relay bound to it
- **THEN** the relays column shows an explicit placeholder rather than an empty cell

#### Scenario: One namespace cannot be read

- **WHEN** the controller refuses the listing of one reachable namespace
- **THEN** the other namespaces' plugins are still listed
- **AND** the refusal is stated for that namespace

### Requirement: Plugin disabling has one path

Disabling a plugin SHALL be performed solely through `Flezha.Service.PluginManager.disable/3`, naming the plugin and its namespace. The UI SHALL NOT contain a direct-to-relay fallback disable path.

#### Scenario: Disabling a known plugin

- **WHEN** an operator disables a listed plugin
- **THEN** `Service.PluginManager.disable/3` is called with its name and namespace, and the plugin leaves the list

#### Scenario: The plugin is unknown to the plugin manager

- **WHEN** `disable/3` answers an error with code `plugin.not_found`
- **THEN** the UI reports that the controller does not know this plugin
- **AND** no alternative disable path is attempted

#### Scenario: No fallback path exists in the code

- **WHEN** the codebase is searched for `IOBindingPlugin` or `disable_plugin_direct`
- **THEN** no occurrence exists

### Requirement: The installed-plugin catalog

The plugins screen SHALL list the plugin packages installed on the controller from `Flezha.Service.Fleet.installed_plugins/1`, with each entry's id, version, and load status (`loaded`, `refused`, `pending`, or `removed`), presented separately from the list of enabled plugins. The UI SHALL NOT install, upgrade, or uninstall a plugin.

#### Scenario: Plugins are installed

- **WHEN** an operator opens the plugins screen
- **THEN** each installed package is listed with its id, version, and load status

#### Scenario: Installer verbs are absent

- **WHEN** the plugins screen is rendered
- **THEN** no control installs, upgrades, or uninstalls a plugin
- **AND** the screen names `flz plugin` as where those verbs live

#### Scenario: The installer is not available

- **WHEN** the installed-plugin read answers `{:error, {:api_missing, ...}}`
- **THEN** the catalog states it is unavailable on this controller and the enabled list still renders

### Requirement: Per-provider option help

When a provider is selected on the attach form, the UI SHALL show the provider's own help text, read through `Flezha.Service.Fleet.provider/2`, beside the options it asks for, so the form explains the options rather than presenting a bare field.

#### Scenario: A provider with help

- **WHEN** an operator selects a provider whose help the controller answers
- **THEN** the help text is shown with the options field

#### Scenario: A provider without help

- **WHEN** the controller answers no help for the selected provider, or refuses the read
- **THEN** the options field renders without help rather than the form failing

### Requirement: Plugins are enabled by name and bound to a relay

The UI SHALL attach a plugin to a relay by calling `Flezha.Service.PluginManager.enable/3` with the plugin's name and the named fields `provider` (the provider id as text, such as `relay_stdout`), `opts` (a map keyed by text), `namespace`, `relay_id`, and `hooks` (the hook names, with their options), so the controller enables the plugin in the namespace and binds it to the relay in one call. The UI SHALL NOT construct a plugin struct, resolve a provider module, or turn option names into atoms itself.

#### Scenario: Attaching a plugin to a relay

- **WHEN** an operator on a relay's detail screen names a plugin, selects a provider and one or more hooks, and submits the form
- **THEN** `Service.PluginManager.enable/3` is called with that name, the provider id, the options, the namespace, the relay's id, and the hooks
- **AND** the plugin appears among the relay's plugins on success

#### Scenario: Hook selections never reach the provider's options

- **WHEN** a plugin form supplies hook selections alongside provider options
- **THEN** the selections are sent as `hooks`
- **AND** they are absent from the `opts` map sent to the provider

#### Scenario: Only the provider's hooks are offered

- **WHEN** an operator has selected a provider
- **THEN** the hooks offered are those `Flezha.Service.Fleet.provider/2` reports the provider supports

#### Scenario: The name is already enabled with this provider

- **WHEN** the controller answers `outcome: :already_enabled`
- **THEN** the form reports that the plugin was already enabled and that the relay is bound to it

#### Scenario: The controller rejects the plugin

- **WHEN** `Service.PluginManager.enable/3` answers an error, for example `plugin.id_taken`, `plugin.unknown_options`, or `plugin.init_after_start`
- **THEN** the error's message is displayed on the form and no plugin is listed

