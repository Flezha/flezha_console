# plugin-management Specification

## Purpose
TBD - created by archiving change resync-with-flezha-runtime. Update Purpose after archive.
## Requirements
### Requirement: Plugins are constructed under the current plugin model

The UI SHALL enable plugins by constructing a `%Flezha.Plugin{}` carrying `id`, `provider` module, `namespace`, `operative_id`, an `opts` map, and a `subscriptions` list of `{extension_name, sub_opts}` tuples, and passing it to `Flezha.Service.PluginManager.enable_plugin/2`.

#### Scenario: Enabling a plugin on an operative

- **WHEN** an operator selects a provider, an operative, and one or more extensions, and submits the form
- **THEN** a `%Flezha.Plugin{}` with those subscriptions is sent to `PluginManager.enable_plugin/2`
- **AND** the plugin appears in the plugin list on success

#### Scenario: Subscription directives never reach the provider

- **WHEN** a plugin form supplies extension or trigger selections alongside provider options
- **THEN** those selections are converted into `subscriptions`
- **AND** they are absent from the `opts` map sent to the provider

#### Scenario: The controller rejects the plugin

- **WHEN** `PluginManager.enable_plugin/2` returns `{:error, reason}`
- **THEN** the reason is displayed on the form and no plugin is listed

### Requirement: Provider discovery

The UI SHALL populate the provider selector from the controller at runtime using `Flezha.Service.ConfigManager.get_enabled_plugins/0` and `get_provider_info/0`, and SHALL NOT hard-code a provider list.

#### Scenario: Providers are enabled on the controller

- **WHEN** an operator opens the plugin form
- **THEN** the selectable providers are exactly those the controller reports as enabled

#### Scenario: A provider declares its options

- **WHEN** the controller's provider info describes a provider's option fields
- **THEN** the form presents those fields for that provider

### Requirement: Plugin listing

The UI SHALL list enabled plugins from `Flezha.Service.PluginManager.get_plugins/0`, showing each plugin's id, provider, namespace, operative, and subscribed extensions. The same LiveView SHALL additionally serve a namespace-scoped listing at `/namespaces/:ns/plugins`, filtering on the namespace each enabled plugin already carries. Because the controller exposes no namespaced plugin call, the scoped screen SHALL state that its scope is a view filter over the full listing rather than a controller-side scope.

#### Scenario: Plugins are enabled

- **WHEN** an operator opens the plugins screen
- **THEN** each enabled plugin is listed with its provider and subscribed extensions

#### Scenario: A namespace's own plugins

- **WHEN** an operator opens `/namespaces/:ns/plugins`
- **THEN** only plugins bound to an operative in that namespace are listed

#### Scenario: The scope is honestly labelled

- **WHEN** the scoped plugins screen is rendered
- **THEN** it states that the namespace is applied as a view filter over the controller's full plugin listing

#### Scenario: One LiveView serves both routes

- **WHEN** the codebase is inspected
- **THEN** `/plugins` and `/namespaces/:ns/plugins` are served by the same LiveView module

#### Scenario: A plugin is not bound to an operative

- **WHEN** a listed plugin has no `operative_id`
- **THEN** the operative column shows an explicit placeholder rather than an empty cell

#### Scenario: An unbound plugin under a namespace scope

- **WHEN** a plugin carries no namespace and a namespace scope is applied
- **THEN** it is excluded from the scoped listing rather than shown under an arbitrary namespace

### Requirement: Plugin disabling has one path

Disabling a plugin SHALL be performed solely through `Flezha.Service.PluginManager.disable_plugin/1`. The UI SHALL NOT contain a direct-to-operative fallback disable path.

#### Scenario: Disabling a known plugin

- **WHEN** an operator disables a listed plugin
- **THEN** `PluginManager.disable_plugin/1` is called and the plugin leaves the list

#### Scenario: The plugin is unknown to the plugin manager

- **WHEN** `disable_plugin/1` reports the plugin is not known
- **THEN** the UI reports that the controller does not know this plugin
- **AND** no alternative disable path is attempted

#### Scenario: No fallback path exists in the code

- **WHEN** the codebase is searched for `IOBindingPlugin` or `disable_plugin_direct`
- **THEN** no occurrence exists

### Requirement: The installed-plugin catalog

The plugins screen SHALL list the plugins installed on the controller from `Flezha.Plugin.Installer.list/0`, with each entry's id, version, and whether it is enabled, presented separately from the list of enabled plugin instances. The UI SHALL NOT install, upgrade, or uninstall a plugin.

#### Scenario: Plugins are installed

- **WHEN** an operator opens the plugins screen
- **THEN** each installed plugin is listed with its id, version, and enabled state

#### Scenario: An installed plugin is not enabled

- **WHEN** an installed plugin has no enabled instance
- **THEN** it appears in the catalog and not in the enabled list

#### Scenario: Installer verbs are absent

- **WHEN** the plugins screen is rendered
- **THEN** no control installs, upgrades, or uninstalls a plugin
- **AND** the screen names `flz plugin` as where those verbs live

#### Scenario: The installer is not available

- **WHEN** the installer read answers `{:error, {:api_missing, ...}}`
- **THEN** the catalog states it is unavailable on this controller and the enabled list still renders

### Requirement: Per-provider option help

When a provider is selected on the attach form, the UI SHALL show the provider's own documentation for its option fields, so the form explains the options it asks for rather than presenting bare field names.

#### Scenario: A provider with documented options

- **WHEN** an operator selects a provider whose options are documented
- **THEN** each option field carries its description

#### Scenario: A provider without documentation

- **WHEN** the controller reports no help for the selected provider
- **THEN** the fields render without descriptions rather than the form failing

