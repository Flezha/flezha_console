defmodule FlezhaConsole.DeadLetters do
  @moduledoc """
  Dead letters an operator has marked seen.

  The controller's queue knows nothing of it: seen is this console's own
  record, kept per entry reference and generation, so an entry that is
  replayed and parks again under a new generation is unseen again. A seen
  dead letter stays in the queue; it only stops counting as a problem.
  """

  import Ecto.Query

  alias FlezhaConsole.DeadLetters.Acknowledgement
  alias FlezhaConsole.Repo
  alias FlezhaConsole.Service.NodeManager

  @doc """
  The reference the controller's own verbs take for an entry as
  `NodeManager.dlq_list/2` answers it: its `class/tasklet/id` triple.
  """
  def ref(entry), do: "#{entry["relay_class"]}/#{entry["tasklet_id"]}/#{entry["id"]}"

  @doc "An entry's generation; a first park reports none."
  def generation(entry), do: entry["generation"] || 1

  @doc """
  Marks `entries`, each `%{ref:, generation:, relay_class:}`, seen by `who`.
  An entry already seen keeps its first mark.
  """
  def mark_seen(entries, who) when is_binary(who) do
    now = DateTime.utc_now(:second)

    rows =
      for entry <- entries do
        %{
          ref: entry.ref,
          generation: entry.generation,
          relay_class: to_string(entry.relay_class),
          acknowledged_by: who,
          inserted_at: now,
          updated_at: now
        }
      end

    Repo.insert_all(Acknowledgement, rows,
      on_conflict: :nothing,
      conflict_target: [:ref, :generation]
    )

    :ok
  end

  @doc "The `{ref, generation}` pairs of `entries` that are seen."
  def seen(entries) do
    refs = Enum.map(entries, & &1.ref)

    from(a in Acknowledgement, where: a.ref in ^refs, select: {a.ref, a.generation})
    |> Repo.all()
    |> MapSet.new()
    |> MapSet.intersection(MapSet.new(entries, &{&1.ref, &1.generation}))
  end

  @doc """
  `NodeManager.dlq_stats/1`, each row carrying how many of its entries are
  `:seen`, in the cluster answer's shape.

  A class's entries are listed only when something in it was marked seen, and
  then only when its figures or its marks changed since it was last counted,
  or `:dead_letter_seen_ttl_ms` (a minute unless configured) has passed: each
  class's count is kept in `NodeManager`'s read cache beside the figures and
  marks it was counted from, so the usual answer costs one call. The bound
  catches an entry that parked again with the same count and size. Listing a
  class also forgets the marks of its entries that left the queue or parked
  again.
  """
  def stats(token) do
    with {:ok, %{rows: stats} = answer} <- NodeManager.dlq_stats(token) do
      seen = seen_counts(stats, token)

      {:ok, %{answer | rows: Enum.map(stats, &Map.put(&1, :seen, Map.get(seen, key(&1), 0)))}}
    end
  end

  defp key(row), do: {to_string(row[:relay_class]), to_string(row[:tasklet_id])}

  defp seen_counts(stats, token) do
    stats
    |> Enum.filter(&((&1[:entries] || 0) > 0))
    |> Enum.group_by(&to_string(&1[:relay_class]))
    |> seen_in_classes(token)
  end

  defp seen_in_classes(by_class, _token) when by_class == %{}, do: %{}

  defp seen_in_classes(by_class, token) do
    classes = Map.keys(by_class)

    marks =
      from(a in Acknowledgement,
        where: a.relay_class in ^classes,
        select: {a.relay_class, {a.ref, a.generation}, a.id}
      )
      |> Repo.all()
      |> Enum.group_by(&elem(&1, 0), &Tuple.delete_at(&1, 0))

    marks
    |> Enum.flat_map(fn {class, class_marks} ->
      counted(class, class_marks, figures(by_class[class]), token)
    end)
    |> Enum.frequencies()
  end

  # What a class's count was taken from: each tasklet's entries and bytes.
  defp figures(rows),
    do: rows |> Enum.map(&{key(&1), &1[:entries], &1[:bytes]}) |> Enum.sort()

  defp counted(class, marks, figures, token) do
    ids = marks |> Enum.map(&elem(&1, 1)) |> Enum.sort()

    case NodeManager.cached(token, {:dlq_seen, class}) do
      {:ok, {^figures, ^ids, seen}} ->
        seen

      _changed ->
        {seen, held} = seen_in(class, marks, token)
        ttl = Application.get_env(:flezha_console, :dead_letter_seen_ttl_ms, 60_000)
        NodeManager.cache(token, {:dlq_seen, class}, {figures, held, seen}, ttl)
        seen
    end
  end

  # A class whose listing fails counts nothing seen and forgets nothing, and
  # is counted again on the next read.
  defp seen_in(class, marks, token) do
    case NodeManager.dlq_list(class, token) do
      {:ok, %{rows: entries}} ->
        parked = Map.new(entries, &{{ref(&1), generation(&1)}, to_string(&1["tasklet_id"])})
        {held, gone} = Enum.split_with(marks, fn {pair, _id} -> Map.has_key?(parked, pair) end)
        forget(Enum.map(gone, &elem(&1, 1)))

        {for({pair, _id} <- held, do: {class, Map.fetch!(parked, pair)}),
         held |> Enum.map(&elem(&1, 1)) |> Enum.sort()}

      {:error, _reason} ->
        {[], nil}
    end
  end

  defp forget([]), do: :ok
  defp forget(ids), do: Repo.delete_all(from(a in Acknowledgement, where: a.id in ^ids))
end
