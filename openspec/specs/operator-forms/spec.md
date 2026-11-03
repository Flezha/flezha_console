# operator-forms Specification

## Purpose
How the console's forms behave: one field component, dialogs sized by role, JSON
fields that are readable to edit, and values offered from what the controller
reports rather than typed from memory.
## Requirements
### Requirement: One field component

Every labelled form control on the operator screens SHALL be rendered by a single field component in `FlezhaConsoleWeb.CoreComponents`. The control's styling SHALL exist only in that component, so a size, a focus ring, or a border is one decision rather than one per template. The component SHALL support text, number, password, textarea, and select controls, SHALL carry a caller-supplied `data-testid` through to the rendered control unchanged, and SHALL render a field's own errors with the field.

#### Scenario: A form is authored

- **WHEN** a screen needs a labelled input, textarea, or select
- **THEN** it renders the field component rather than hand-written control markup

#### Scenario: Control styling is changed

- **WHEN** the styling of form controls changes
- **THEN** it is edited in the field component alone
- **AND** no template carries a control class string

#### Scenario: A field is addressed by a test

- **WHEN** a field is given a `data-testid`
- **THEN** the rendered control carries that exact value

#### Scenario: A field explains itself

- **WHEN** a field has a constraint or an optional meaning worth stating
- **THEN** the component renders that hint with the field rather than beside it

#### Scenario: A field has an error

- **WHEN** a field is given an error
- **THEN** the component renders the error with that field, not elsewhere on the form

### Requirement: Dialog size is a role, not a class

The dialog component SHALL take the *role* of the dialog — a confirmation, a form, or a wide inspection panel — and map it to a width itself. A caller SHALL NOT pass a raw width class. A dialog carrying a form SHALL be wide enough to read its own fields, and SHALL scroll its panel when it is taller than the viewport.

#### Scenario: A form dialog is opened

- **WHEN** an operator opens a dialog carrying a form
- **THEN** it is rendered at the width every form dialog uses

#### Scenario: The form dialog width is changed

- **WHEN** the width of form dialogs changes
- **THEN** it is edited in the dialog component alone
- **AND** every form dialog changes with it

#### Scenario: A dialog is taller than the viewport

- **WHEN** a dialog's content exceeds the viewport height
- **THEN** the panel scrolls and every field remains reachable

### Requirement: JSON fields are editable

A field taking a JSON document SHALL be rendered tall enough to show a small object without scrolling, and SHALL be monospaced.

#### Scenario: Editing init values

- **WHEN** an operator edits a JSON field such as a relay's init values
- **THEN** the editor shows several lines at once
- **AND** the text is monospaced

### Requirement: Enumerable values are offered, not typed

Where the controller can report the set a field's value must come from — a namespace, a factory, a plugin provider — the field SHALL offer that set as a selection. Free text SHALL remain available only as the fallback for a controller that cannot answer, and SHALL be presented as a fallback rather than as the normal path. A value the controller decides rather than the operator, such as the run of the chosen factory, SHALL be shown read-only and SHALL NOT be offered as a field.

#### Scenario: The controller can report the set

- **WHEN** a field's valid values are known to the controller
- **THEN** the field offers them as a selection

#### Scenario: The controller cannot report the set

- **WHEN** the controller is unreachable or refuses the listing
- **THEN** the field accepts a typed value
- **AND** the form states that the choices could not be read

#### Scenario: The set is empty

- **WHEN** the controller reports that the set is empty
- **THEN** the field says so
- **AND** it does not present an empty selection as if it were a choice

#### Scenario: A value the controller decides

- **WHEN** a form depends on a value the controller fixes, such as whether a factory runs as `flow` or `steps`
- **THEN** the form states that value next to the choice it follows from
- **AND** no control lets the operator set it

### Requirement: Generated fields are typed and checked by one core

Fields the console generates from a type description, the options a plugin provider lists and the properties of a relay entry channel's schema, SHALL be cast and checked by one shared module, `FlezhaConsoleWeb.Live.TypedFields`, built on Ecto schemaless changesets, and rendered by the field component. The core SHALL report every failing field at once, each on its own field, and SHALL answer only the fields that were given. It SHALL NOT turn a field name supplied by the controller into an atom. No screen SHALL parse generated fields by hand beside it.

#### Scenario: Two forms share the core

- **WHEN** the codebase is inspected
- **THEN** the plugin form's option fields and the relay call dialog's channel fields are both checked through `TypedFields`
- **AND** neither screen carries its own parser for typed field values

#### Scenario: Several fields fail at once

- **WHEN** an operator submits a generated form with two fields in error
- **THEN** both fields show their error
- **AND** nothing is sent

#### Scenario: A blank field

- **WHEN** an optional generated field is left blank
- **THEN** it is absent from the value the core answers

#### Scenario: Field names from the controller

- **WHEN** the core checks fields whose names the controller supplied
- **THEN** no atom is created from those names

