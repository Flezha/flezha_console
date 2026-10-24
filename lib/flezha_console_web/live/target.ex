defmodule FlezhaConsoleWeb.Live.Target do
  @moduledoc """
  The namespace and factory a write is aimed at, and the listings it offers
  them from.

  Two forms aim a write at a target — the relay launcher and the schedule
  form — and both need the same four things: the namespaces the bound token can
  reach, the chosen namespace's registered factories, the rule for which of each
  stays chosen when the other moves, and a picker that falls back to free text
  when the controller cannot answer. All four live here, so a third form that
  targets a namespace and a factory writes two tags rather than a third copy.

  Held as one value on the socket:

      target = Target.load_namespaces(Target.new(token))
      {target, form} = Target.aim(target, Target.namespace(target), form)

      <.namespace_field target={@target} name="schedule[namespace]" value={@form["namespace"]}
        testid="schedule-input-namespace" />

  Filled when a form opens and when its namespace moves, never on a refresh
  tick: the catalog costs a controller call per factory, and a listing that
  re-read one per namespace per tick would pay for a form that is usually
  closed.
  """

  use FlezhaConsoleWeb, :html

  alias FlezhaConsole.Service.NodeManager

  # Said by the picker as its prompt and by a form's own validation as its
  # refusal, so the two cannot come to disagree about what an empty namespace is.
  @no_factories "No factories are registered in this namespace"

  @doc "What to say when the chosen namespace registers no factories."
  def no_factories_message, do: @no_factories

  @doc """
  A target with nothing listed yet, read with `token`. `run: :steps` keeps
  only the factories that run as steps, for a form the controller refuses a
  flow factory on.
  """
  def new(token, opts \\ []) do
    %{
      token: token,
      run: Keyword.get(opts, :run),
      namespaces: [],
      namespaces_error: nil,
      factories: [],
      factories_error: nil
    }
  end

  @doc "Lists the namespaces the target's token can reach."
  def load_namespaces(target),
    do: put_namespaces(target, NodeManager.scoped_namespaces(target.token))

  @doc """
  Takes the namespaces a screen has already listed, as `scoped_namespaces/1`
  answers them.

  For a host that loaded them for its own listing: offering the choice then
  costs no second read.
  """
  def put_namespaces(target, {namespaces, error}),
    do: %{target | namespaces: Enum.sort(namespaces), namespaces_error: error}

  @doc """
  Aims at `namespace`: lists its factories and drops the form's chosen factory
  when the new namespace does not register it.

  Answers `{target, form}`. The form key is `"factory_id"` — the controller's
  own field name, which every form carrying a target uses.
  """
  def aim(target, namespace, form) do
    target = load_factories(target, namespace)

    {target, Map.put(form, "factory_id", factory(target, form["factory_id"]))}
  end

  defp load_factories(target, namespace) do
    {factories, error} =
      case String.trim(namespace || "") do
        "" -> {[], nil}
        ns -> NodeManager.ok_or_error(NodeManager.factory_catalog(ns, target.token), [])
      end

    %{target | factories: of_run(factories, target.run), factories_error: error}
  end

  @doc """
  `preferred` when the target can reach it, otherwise the first namespace it can.

  A form seeded with a namespace keeps it while it is reachable; one seeded with
  nothing gets somewhere to start rather than an empty required field.
  """
  def namespace(target, preferred \\ "") do
    if preferred in target.namespaces,
      do: preferred,
      else: List.first(target.namespaces) || ""
  end

  defp of_run(factories, nil), do: factories
  defp of_run(factories, run), do: Enum.filter(factories, &(to_string(&1.run) == to_string(run)))

  # A namespace change re-lists the catalog, and a factory the new namespace does
  # not register must not stay chosen: the write would be refused naming a
  # factory the operator can no longer see in the picker.
  defp factory(target, factory_id) do
    if catalog_entry(target.factories, factory_id), do: factory_id, else: ""
  end

  defp catalog_entry(catalog, factory_id), do: Enum.find(catalog, &(&1.id == factory_id))

  @doc """
  True when the controller reported that this namespace registers no factories.

  Distinct from a catalog that could not be read: that one still accepts a typed
  id, this one has nothing to aim at at all.
  """
  def no_factories?(target), do: target.factories == [] and is_nil(catalog_error(target))

  @doc """
  Why the factory catalog could not be read, or `nil`. A namespace list that
  could not be read leaves no namespace to read a catalog from, so it is the
  catalog's refusal too.
  """
  def catalog_error(target), do: target.factories_error || target.namespaces_error

  # ---- Rendering ----

  @doc "The namespace to write into, offered from what the token can reach."
  attr :target, :map, required: true
  attr :name, :string, required: true
  attr :label, :string, default: "Namespace"
  attr :value, :any, default: nil
  attr :testid, :string, required: true

  def namespace_field(assigns) do
    ~H"""
    <.enumerated_field
      name={@name}
      label={@label}
      value={@value}
      options={Enum.map(@target.namespaces, &{&1, &1})}
      prompt="Select a namespace..."
      empty="No namespaces are reachable"
      error={@target.namespaces_error}
      placeholder="default"
      mono
      testid={@testid}
    />
    """
  end

  @doc "The factory to write against, offered from the chosen namespace's catalog."
  attr :target, :map, required: true
  attr :name, :string, required: true
  attr :label, :string, default: "Factory ID"
  attr :value, :any, default: nil
  attr :testid, :string, required: true

  def factory_field(assigns) do
    ~H"""
    <.enumerated_field
      name={@name}
      label={@label}
      value={@value}
      options={factory_options(@target.factories)}
      prompt="Select a factory..."
      empty={no_factories_message()}
      error={catalog_error(@target)}
      hint={factory_hint(@target.factories, @value)}
      placeholder="store_input"
      mono
      testid={@testid}
    />
    """
  end

  # Each factory carries its description, and a mark when no runner serves it —
  # at the point of choosing rather than after the write is refused.
  defp factory_options(catalog) do
    Enum.map(catalog, fn factory ->
      label =
        [factory.id, factory.description && "— #{factory.description}", unservable(factory)]
        |> Enum.reject(&is_nil/1)
        |> Enum.join(" ")

      {label, factory.id}
    end)
  end

  defp unservable(%{servable?: false}), do: "(no runner)"
  defp unservable(_factory), do: nil

  defp factory_hint(catalog, factory_id) do
    case catalog_entry(catalog, factory_id) do
      %{runners: []} -> "No runner currently serves this factory."
      %{runners: runners} -> "Served by #{Enum.join(runners, ", ")}."
      nil -> nil
    end
  end

  @doc """
  The chosen factory's run, stated read-only: how a relay runs is its
  factory's, announced by its runners, so no form offers to set it.
  """
  attr :target, :map, required: true
  attr :value, :any, default: nil
  attr :testid, :string, required: true

  def factory_run(assigns) do
    assigns = assign(assigns, :run, factory_run_of(assigns.target.factories, assigns.value))

    ~H"""
    <p :if={@run} class="text-xs fcon-quiet" data-testid={@testid}>
      Runs as <span class="font-mono">{@run}</span>, as this factory's runners announce it.
    </p>
    """
  end

  defp factory_run_of(catalog, factory_id) do
    case catalog_entry(catalog, factory_id) do
      %{run: run} when not is_nil(run) -> to_string(run)
      _unknown -> nil
    end
  end
end
