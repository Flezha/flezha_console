# operator-forms Specification

## Purpose
TBD - created by archiving change add-operative-launcher. Update Purpose after archive.
## Requirements
### Requirement: One field component

Every labelled form control on the operator screens SHALL be rendered by a single field component in `FlezhaUiWeb.CoreComponents`. The control's styling SHALL exist only in that component, so a size, a focus ring, or a border is one decision rather than one per template. The component SHALL support text, number, textarea, and select controls, and SHALL carry a caller-supplied `data-testid` through to the rendered control unchanged.

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

- **WHEN** an operator edits a JSON field such as an operative's init values
- **THEN** the editor shows several lines at once
- **AND** the text is monospaced

### Requirement: Enumerable values are offered, not typed

Where the controller can report the set a field's value must come from — a namespace, a factory, an operative kind — the field SHALL offer that set as a selection. Free text SHALL remain available only as the fallback for a controller that cannot answer, and SHALL be presented as a fallback rather than as the normal path.

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

