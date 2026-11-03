# plugin-management Specification

## Purpose
TBD - created by archiving change resync-with-flezha-runtime. Update Purpose after archive.
## Requirements
### Requirement: Provider discovery

The UI SHALL populate the provider selector from the controller at runtime using `Flezha.Service.Fleet.providers/1`, and SHALL NOT hard-code a provider list. When the selected provider's description from `Flezha.Service.Fleet.provider/2` carries an `options` list, the form SHALL take each listed option through a field of its own. Only when the description carries no `options` list, as from a controller that predates it or whose description could not be read, SHALL the form take the provider's options as one JSON object. In every case the form SHALL show the provider's help beside the options.

#### Scenario: Providers are available on the controller

- **WHEN** an operator opens the plugin form
- **THEN** the selectable providers are exactly those `Service.Fleet.providers/1` reports, each by its id

#### Scenario: A provider that lists its options

- **WHEN** an operator selects a provider whose description carries a non-empty `options` list
- **THEN** the form offers one field per listed option
- **AND** no single JSON field for the options is offered

#### Scenario: A provider that takes no options

- **WHEN** the provider's description carries an empty `options` list
- **THEN** the form states that the provider takes no options and offers no options field

#### Scenario: A controller that does not list options

- **WHEN** the provider's description carries no `options` list
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

When a provider is selected on the attach form, the UI SHALL show the provider's own help text, read through `Flezha.Service.Fleet.provider/2`, beside the options it asks for, so the form explains the options rather than presenting bare fields. When the options are offered field by field, each field SHALL also carry its option's own description.

#### Scenario: A provider with help

- **WHEN** an operator selects a provider whose help the controller answers
- **THEN** the help text is shown with the options

#### Scenario: A provider without help

- **WHEN** the controller answers no help for the selected provider, or refuses the read
- **THEN** the options render without help rather than the form failing

#### Scenario: An option with a description

- **WHEN** a listed option carries a description
- **THEN** its field shows that description as its hint

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

### Requirement: A refused package explains itself

Each row of the installed-package catalog SHALL show the providers its package declares. A refused package SHALL show the error it was refused with, its code, message and hint, through the console's error component. A pending package SHALL show the version loaded before it when there is one. The provider listing SHALL state how many packages the controller refused at boot, from the `refused` count `Flezha.Service.Fleet.providers/1` answers, and SHALL NOT offer a refused package's providers for enabling.

#### Scenario: A package was refused

- **WHEN** a package was refused at boot
- **THEN** its row shows the error's code, message and hint
- **AND** its providers are not offered on the enable form

#### Scenario: A loaded package

- **WHEN** a package loaded at boot
- **THEN** its row lists the providers it declares

#### Scenario: A package replaced since boot

- **WHEN** the plugin root holds a newer package than the one loaded at boot
- **THEN** its pending row shows the version still loaded

#### Scenario: The refused count

- **WHEN** the controller refused one or more packages at boot
- **THEN** the provider listing states how many were refused and points at the catalog

### Requirement: Enabling states where a plugin will not run

After a plugin is enabled, the UI SHALL show whether it was enabled or was already enabled, and SHALL name each controller in the `lacking` list `Flezha.Service.PluginManager.enable/3` answers as a controller that holds the namespace but lacks the provider, where the plugin does not run.

#### Scenario: Every controller has the provider

- **WHEN** an enable answers an empty `lacking` list
- **THEN** the UI reports the plugin enabled with no warning

#### Scenario: Some controllers lack the provider

- **WHEN** an enable answers a non-empty `lacking` list
- **THEN** the UI reports the plugin enabled
- **AND** a warning names each lacking controller and says the plugin does not run there

#### Scenario: The plugin was already enabled

- **WHEN** an enable answers `already_enabled`
- **THEN** the UI says the plugin was already enabled rather than reporting a new one

### Requirement: Bindings and options are changed apart from enabling

Each enabled plugin SHALL offer a control to change its options and, for a controller plugin, its hooks (`Flezha.Service.PluginManager.update/3`). Each enabled relay plugin SHALL additionally offer controls to bind it to a further relay with hooks and a channel (`bind/3`) and to unbind it from a relay while it stays enabled (`unbind/3`). These controls SHALL reuse the enable form's fields and provider help, and a bind SHALL start with the plugin's own hooks ticked. The plugins screen SHALL show the bind control beside each relay plugin's bound relays, and each provider SHALL offer Enable, which opens the enable flow with that provider chosen. Attaching from a relay screen SHALL also offer, beside the providers, the relay plugins already enabled in that namespace that the relay does not hold; choosing one binds it to that relay through `bind/3` instead of enabling another plugin. Unbinding SHALL require an explicit confirmation. An update SHALL report whether it was applied live, by restarting the plugin's copies, or changed nothing, and the relays bound to it.

#### Scenario: Binding to another relay

- **WHEN** an operator binds an enabled plugin to a relay
- **THEN** `bind/3` is called with the plugin's name and the relay, hooks and channel chosen
- **AND** the relay appears among the plugin's bound relays on the next read

#### Scenario: Binding an enabled plugin from the relay screen

- **WHEN** an operator attaches a plugin on a relay screen and chooses one already enabled in the namespace
- **THEN** `bind/3` is called for that relay with the plugin's hooks, and `enable/3` is not called

#### Scenario: The relay is already bound

- **WHEN** a bind answers `already_bound`
- **THEN** the UI says the relay already holds the binding

#### Scenario: Unbinding a relay

- **WHEN** an operator confirms unbinding a relay from a plugin
- **THEN** `unbind/3` is called
- **AND** the plugin stays listed as enabled without that relay

#### Scenario: Updating options

- **WHEN** an operator changes a plugin's options and submits
- **THEN** `update/3` is called with the new options
- **AND** the UI reports whether they were applied live, by restart, or changed nothing

### Requirement: Controller plugins are enabled with controller hooks

When the selected provider's type, from `Flezha.Service.Fleet.provider/2`, is `controller`, the enable form SHALL NOT ask for a relay and SHALL offer the controller hooks the provider supports — of `on_relay_started`, `on_relay_stopped`, `on_relay_failed`, `on_dead_letter` and `on_plugin_unhealthy` — and whether the plugin runs as one `single` copy for the whole cluster. A relay plugin's form SHALL offer only relay hooks.

#### Scenario: Enabling a controller plugin

- **WHEN** an operator selects a controller provider such as `hook_webhook`, picks hooks and submits
- **THEN** `enable/3` is called with those hooks and no relay
- **AND** the plugin is listed with its hooks and no bound relay

#### Scenario: A relay provider

- **WHEN** an operator selects a relay provider
- **THEN** the form asks for a relay and offers relay hooks only

#### Scenario: A single controller plugin

- **WHEN** an operator enables a controller plugin with `single` chosen
- **THEN** `enable/3` is called with `single: true`

### Requirement: Plugin rows show where a plugin runs

Each enabled plugin row SHALL show, from `Flezha.Service.PluginManager.enabled/2`, whether it is `single`, the controllers it runs on, and, for a controller plugin, its hooks and the controllers whose copy lags behind the events sent to it.

#### Scenario: A plugin running on several controllers

- **WHEN** a plugin runs on more than one controller
- **THEN** each controller is listed on its row

#### Scenario: A lagging controller plugin

- **WHEN** a controller plugin's copy lags on a controller
- **THEN** that controller is named as lagging on the plugin's row

#### Scenario: Nothing lags

- **WHEN** the `lagging` list is empty
- **THEN** the row shows no lag warning

### Requirement: A provider's options are entered field by field

For a provider whose description lists its options, the plugin form SHALL render one field per option, chosen by the option's type:
- a number field bounded by the option's minimum and maximum for `int`;
- a true/false selection whose blank choice means "not given" for `bool`;
- a selection of the option's values for `enum`;
- a text field for `string`;
- a comma-separated text field for `names` and `list`;
- a JSON field that takes an object for `map`;
- a JSON field that takes any JSON value for `json`, `any` and a type the console does not know.

An option of type `pid` SHALL NOT be offered. Each field SHALL show its option's default as its placeholder. On enable, a required option SHALL be marked as required.

Before any call, the form SHALL check every field: a required option left empty on enable, a number outside its bounds or not a whole number, a value outside an enum, and text that is not valid JSON, or not a JSON object where an object is required. Every failure SHALL be reported on its own field, and no call SHALL be made while any remains.

Only the options the operator filled in SHALL be sent, keyed by their names as text, with each value in its type: an integer, a boolean, a list of text, or the decoded JSON value. On update, every listed option SHALL be offered empty. A filled option SHALL be merged into the plugin's options and a blank one left as it is. Each field SHALL state whether a change to it is applied in place (a `live` option) or restarts the plugin's copies.

When the controller refuses the enable or the update with an error whose details name one or more options the form offered, the error SHALL be shown on those fields with its code. Otherwise it SHALL be shown on the form as today.

#### Scenario: Each type gets its control

- **WHEN** a provider lists an `int` option with bounds, a `bool`, an `enum`, a `string`, a `names`, a `map` and a `json` option
- **THEN** the form renders a bounded number field, a true/false selection, a selection of the enum's values, a text field, a comma-separated text field and two JSON fields
- **AND** each shows its option's default as its placeholder

#### Scenario: A process option is not offered

- **WHEN** a provider lists an option of type `pid`
- **THEN** no field is rendered for it

#### Scenario: Typed values are sent

- **WHEN** an operator fills an `int`, a `bool`, a `names` and a `json` option, leaves the others blank and enables the plugin
- **THEN** `enable/3` is called with `opts` holding exactly those four options, as an integer, a boolean, a list of text and the decoded JSON value, keyed by their names as text

#### Scenario: A required option is left empty

- **WHEN** an operator enables a plugin with a required option left empty
- **THEN** that option's field states that it is required
- **AND** no call is made

#### Scenario: A number outside its bounds

- **WHEN** an operator enters a number above an option's maximum or below its minimum
- **THEN** that option's field states the bound it broke
- **AND** no call is made

#### Scenario: Invalid JSON in an object option

- **WHEN** an operator enters text that is not a JSON object into a `map` option
- **THEN** that option's field states that it must be a JSON object
- **AND** no call is made

#### Scenario: Updating options

- **WHEN** an operator opens the update form of an enabled plugin, fills one option and submits
- **THEN** `update/3` is called with `opts` holding only that option
- **AND** a required option left blank is not reported
- **AND** each field states whether a change to it is applied in place or restarts the plugin's copies

#### Scenario: The controller refuses an option it names

- **WHEN** the controller refuses with an error whose details name an option the form offered, such as `plugin.url_scheme_unsupported` on `url`
- **THEN** the error's message and code are shown on that option's field

#### Scenario: The controller refuses without naming an option

- **WHEN** the controller refuses with an error whose details name no offered option
- **THEN** the error is shown on the form with its code and hint, as today

### Requirement: A secret option is never shown or echoed

An option the controller marks `transient` SHALL be entered through a password field. Its value SHALL NOT be rendered into the page, not as the field's value, a placeholder, a flash or an error message, and it SHALL be filtered from the console's request and event logs. A controller error that names a secret option SHALL be shown on its field without the controller's message, which may carry the value. On update, a secret left blank SHALL leave the stored value as it is.

#### Scenario: Entering a secret

- **WHEN** an operator types a value into a secret option and submits
- **THEN** the value is sent as that option
- **AND** the rendered page does not contain it, before or after the submit

#### Scenario: The controller refuses a secret

- **WHEN** the controller refuses with an error naming a secret option
- **THEN** the field states that the controller refused the value, with the error's code
- **AND** the rendered page does not contain the value

#### Scenario: Updating without the secret

- **WHEN** an operator updates a plugin and leaves its secret option blank
- **THEN** the secret is absent from the `opts` sent

#### Scenario: The secret in the logs

- **WHEN** the console logs a form event carrying a secret option
- **THEN** the secret's value is logged as filtered

### Requirement: The relay screen lists and unbinds its own bindings

The relay screen's plugins panel SHALL list every binding the controller declares for the relay: the bindings its hook table holds, and the declared bindings it does not hold — a binding whose plugin was disabled or whose provider did not start — read through `Flezha.Service.Relay.relay_plugins/2` and marked as not running. Each binding SHALL offer an unbind control, gated on `PluginManager.unbind`, that calls `Flezha.Service.PluginManager.unbind/3` for this relay alone after an explicit confirmation. The relay screen SHALL NOT disable a plugin: disabling is a namespace-wide action, offered on the plugins screen.

#### Scenario: A running binding is unbound

- **WHEN** an operator confirms unbinding a plugin on the relay screen
- **THEN** `unbind/3` is called with the plugin's name, the relay's namespace and the relay's id
- **AND** the plugin stays enabled for the other relays it is bound to

#### Scenario: A binding that is not running

- **WHEN** the controller declares a binding for the relay that its hook table does not hold
- **THEN** the binding is listed, marked as not running, with an unbind control
- **AND** confirming the unbind removes it

#### Scenario: Cancelling the unbind

- **WHEN** an operator cancels the unbind confirmation
- **THEN** no call is made and the binding is still listed

