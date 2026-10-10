defmodule FlezhaUiWeb.Live.TypedFields do
  @moduledoc """
  Fields generated from a type description, cast and checked in one place: a
  plugin provider's options and the properties of a relay entry channel's
  schema.

  A field is described by a spec:

      %{name: "timeout_ms", kind: :int, required: false, default: 5000, min: 1,
        max: 60000, values: nil, doc: "Budget for one request"}

  Only `name` and `kind` are needed; the rest are read when present. The kinds
  are `:string`, `:int`, `:number`, `:bool`, `:enum`, `:list`, `:object`,
  `:json` and `:secret`.

      case TypedFields.changeset(specs, params, required?: true) do
        :too_many -> ...
        changeset -> TypedFields.values(changeset)
      end

  `values/1` answers only the fields that were given, each in its type, or
  every failing field's `{msg, opts}` error at once. `typed_inputs/1` renders
  the fields with those errors.

  Names come from the controller, so they are never made atoms: the changeset
  is keyed by a fixed set of slot atoms paired with the specs, and names are
  put back on the way out.
  """

  use FlezhaUiWeb, :html

  import Ecto.Changeset

  @slots for i <- 0..127, do: :"f#{i}"
  @slot_count length(@slots)
  @slot_order @slots |> Enum.with_index() |> Map.new()

  @doc "Whether `specs` fit in one changeset."
  def fits?(specs), do: length(specs) <= @slot_count

  @doc """
  A schemaless changeset over `specs`, cast from `params` keyed by field name,
  or `:too_many` when there are more specs than slots.

  `required?: true` checks each spec marked `required`.
  """
  def changeset(specs, params, opts \\ []) do
    if fits?(specs) do
      slotted = Enum.zip(@slots, specs)
      prepared = Enum.map(slotted, fn {slot, spec} -> {slot, spec, prepare(spec, params)} end)

      types = Map.new(prepared, fn {slot, spec, raw} -> {slot, ecto_type(spec.kind, raw)} end)
      kinds = Map.new(slotted, fn {slot, spec} -> {slot, spec.kind} end)

      cast_params =
        for {slot, _spec, {:ok, value}} <- prepared, into: %{}, do: {Atom.to_string(slot), value}

      required =
        if Keyword.get(opts, :required?, false),
          do: for({slot, spec} <- slotted, Map.get(spec, :required) == true, do: slot),
          else: []

      data = %{__names__: Map.new(slotted, fn {slot, spec} -> {slot, spec.name} end)}

      {data, types}
      |> cast(cast_params, Map.keys(types), message: &cast_message(kinds[&1], &2))
      |> add_prepare_errors(prepared)
      |> validate_required(required, message: "is required")
      |> validate_specs(slotted)
    else
      :too_many
    end
  end

  @doc "The given fields as `{:ok, %{name => value}}`, or `{:error, errors/1}`."
  def values(%Ecto.Changeset{valid?: true, changes: changes, data: %{__names__: names}}),
    do: {:ok, Map.new(changes, fn {slot, value} -> {names[slot], value} end)}

  def values(%Ecto.Changeset{} = changeset), do: {:error, errors(changeset)}

  @doc "Every error as `{name, {msg, opts}}`, in field order."
  def errors(%Ecto.Changeset{errors: errors, data: %{__names__: names}}) do
    errors
    |> Enum.sort_by(fn {slot, _error} -> @slot_order[slot] end)
    |> Enum.map(fn {slot, error} -> {names[slot], error} end)
  end

  # ---- Casting ----

  # Text a kind has to decode before Ecto can cast it. `:skip` leaves the field
  # out of the cast, so it reads as not given; `{:error, msg}` leaves it out
  # with that error on it.
  defp prepare(spec, params) do
    case Map.get(params, spec.name) do
      nil -> :skip
      raw when is_binary(raw) -> prepare_text(spec.kind, raw)
      _structured -> {:error, "is invalid"}
    end
  end

  defp prepare_text(:list, raw) do
    case raw |> String.split(",") |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == "")) do
      [] -> :skip
      items -> {:ok, items}
    end
  end

  defp prepare_text(kind, raw) when kind in [:object, :json] do
    case String.trim(raw) do
      "" ->
        :skip

      text ->
        case Jason.decode(text) do
          {:ok, value} -> {:ok, value}
          {:error, _reason} -> {:error, "is not valid JSON"}
        end
    end
  end

  defp prepare_text(_kind, raw), do: {:ok, raw}

  # A `:number` written without a fraction or an exponent stays an integer.
  defp ecto_type(:number, {:ok, raw}) when is_binary(raw) do
    if String.contains?(raw, [".", "e", "E"]), do: :float, else: :integer
  end

  defp ecto_type(:number, _raw), do: :float
  defp ecto_type(:int, _raw), do: :integer
  defp ecto_type(:bool, _raw), do: :boolean
  defp ecto_type(:list, _raw), do: {:array, :string}
  defp ecto_type(:object, _raw), do: :map
  defp ecto_type(:json, _raw), do: :any
  defp ecto_type(_text, _raw), do: :string

  defp cast_message(:int, _meta), do: "must be a whole number"
  defp cast_message(:number, _meta), do: "must be a number"
  defp cast_message(:bool, _meta), do: "must be true or false"
  defp cast_message(:object, _meta), do: "must be a JSON object"
  defp cast_message(_kind, _meta), do: nil

  defp add_prepare_errors(changeset, prepared) do
    Enum.reduce(prepared, changeset, fn
      {slot, _spec, {:error, message}}, acc -> add_error(acc, slot, message)
      _given_or_blank, acc -> acc
    end)
  end

  defp validate_specs(changeset, slotted) do
    Enum.reduce(slotted, changeset, fn {slot, spec}, acc ->
      acc
      |> validate_bounds(slot, spec)
      |> validate_enum(slot, spec)
    end)
  end

  # Bounds are read only on the numeric kinds, where Ecto can compare them.
  defp validate_bounds(changeset, slot, %{kind: kind} = spec) when kind in [:int, :number] do
    changeset
    |> validate_bound(slot, :greater_than_or_equal_to, Map.get(spec, :min), "at least")
    |> validate_bound(slot, :less_than_or_equal_to, Map.get(spec, :max), "at most")
  end

  defp validate_bounds(changeset, _slot, _spec), do: changeset

  defp validate_bound(changeset, slot, bound, number, said) when is_number(number),
    do: validate_number(changeset, slot, [{bound, number}, message: "must be #{said} %{number}"])

  defp validate_bound(changeset, _slot, _bound, _no_bound, _said), do: changeset

  # An enum is chosen by its text and answered as the value it lists, so a
  # numeric enum keeps its type.
  defp validate_enum(changeset, slot, %{kind: :enum, values: values}) when is_list(values) do
    by_text = Map.new(values, &{to_string(&1), &1})
    texts = Enum.map(values, &to_string/1)

    changeset
    |> validate_inclusion(slot, texts,
      message: {"must be one of %{values}", values: Enum.join(texts, ", ")}
    )
    |> update_change(slot, &Map.get(by_text, &1, &1))
  end

  defp validate_enum(changeset, _slot, _spec), do: changeset

  # ---- Rendering ----

  @doc """
  One `CoreComponents.input/1` per spec, read from `form` by name.

  Each field gets its value and its errors explicitly rather than through a
  `FormField`, whose `used_input?/1` gating would hide the error of a required
  field the operator never touched. A `:secret` is posted under `secret_name`
  and always rendered empty, so its value never travels back to the browser.
  """
  attr :specs, :list, required: true
  attr :form, Phoenix.HTML.Form, required: true, doc: "the params and errors, keyed by name"
  attr :secret_name, :string, default: nil, doc: "the param prefix a `:secret` posts under"
  attr :testid, :string, required: true, doc: "the prefix of each field's test id"

  def typed_inputs(assigns) do
    ~H"""
    <.input
      :for={spec <- @specs}
      id={@testid <> spec.name}
      name={input_name(@form, @secret_name, spec)}
      type={input_type(spec.kind)}
      label={spec.name <> if(Map.get(spec, :required), do: " *", else: "")}
      hint={hint(spec)}
      value={if spec.kind != :secret, do: @form[spec.name].value}
      errors={Enum.map(@form[spec.name].errors, &translate_error/1)}
      options={options(spec)}
      prompt={prompt(spec)}
      placeholder={placeholder(spec)}
      step={step(spec.kind)}
      min={spec.kind in [:int, :number] && Map.get(spec, :min)}
      max={spec.kind in [:int, :number] && Map.get(spec, :max)}
      autocomplete={spec.kind == :secret && "new-password"}
      mono={spec.kind in [:string, :list, :object, :json]}
      data-testid={@testid <> spec.name}
    />
    """
  end

  defp input_name(_form, secret_name, %{kind: :secret, name: name}), do: "#{secret_name}[#{name}]"
  defp input_name(form, _secret_name, %{name: name}), do: form[name].name

  defp input_type(kind) when kind in [:int, :number], do: "number"
  defp input_type(kind) when kind in [:bool, :enum], do: "select"
  defp input_type(kind) when kind in [:object, :json], do: "textarea"
  defp input_type(:secret), do: "password"
  defp input_type(_text), do: "text"

  defp step(:int), do: "1"
  defp step(:number), do: "any"
  defp step(_kind), do: nil

  # A list is typed comma-separated, unless its description already says so.
  defp hint(%{kind: :list} = spec) do
    case Map.get(spec, :doc) do
      nil -> "comma-separated"
      doc -> if doc =~ "comma-separated", do: doc, else: doc <> " — comma-separated"
    end
  end

  defp hint(spec), do: Map.get(spec, :doc)

  defp options(%{kind: :bool}), do: ~w(true false)

  defp options(%{kind: :enum, values: values}) when is_list(values),
    do: Enum.map(values, &to_string/1)

  defp options(_spec), do: nil

  defp prompt(%{kind: kind} = spec) when kind in [:bool, :enum] do
    case Map.get(spec, :default) do
      nil -> ""
      default -> "default: #{default_text(kind, default)}"
    end
  end

  defp prompt(_spec), do: nil

  defp placeholder(%{kind: kind}) when kind in [:bool, :enum, :secret], do: nil
  defp placeholder(spec), do: default_text(spec.kind, Map.get(spec, :default))

  defp default_text(_kind, nil), do: nil
  defp default_text(kind, value) when kind in [:object, :json], do: json_text(value)

  defp default_text(:list, items) when is_list(items),
    do: Enum.map_join(items, ", ", &default_text(:string, &1))

  defp default_text(_kind, value) when is_binary(value) or is_number(value) or is_atom(value),
    do: to_string(value)

  defp default_text(_kind, value), do: json_text(value)

  defp json_text(value) do
    case Jason.encode(value) do
      {:ok, text} -> text
      {:error, _reason} -> inspect(value)
    end
  end
end
