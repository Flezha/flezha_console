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

The UI SHALL list enabled plugins from `Flezha.Service.PluginManager.get_plugins/0`, showing each plugin's id, provider, namespace, operative, and subscribed extensions.

#### Scenario: Plugins are enabled

- **WHEN** an operator opens the plugins screen
- **THEN** each enabled plugin is listed with its provider and subscribed extensions

#### Scenario: A plugin is not bound to an operative

- **WHEN** a listed plugin has no `operative_id`
- **THEN** the operative column shows an explicit placeholder rather than an empty cell

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

