defmodule FlezhaUiWeb.Live.TypedFieldsTest do
  @moduledoc """
  The one core that casts and checks generated fields: every kind with a
  valid, an invalid and a blank entry, requirement on and off, bounds, enum
  values keeping their type, and names that never become atoms.
  """

  # Not async: the atom count is read across the whole VM.
  use ExUnit.Case, async: false

  alias FlezhaUiWeb.Live.TypedFields

  defp spec(name, kind, extra \\ %{}), do: Map.merge(%{name: name, kind: kind}, extra)

  defp check(specs, params, opts \\ []) do
    specs |> TypedFields.changeset(params, opts) |> TypedFields.values()
  end

  defp messages({:error, errors}) do
    Map.new(errors, fn {name, error} ->
      {name, FlezhaUiWeb.CoreComponents.translate_error(error)}
    end)
  end

  describe "each kind" do
    test "string" do
      specs = [spec("s", :string)]
      assert check(specs, %{"s" => "text"}) == {:ok, %{"s" => "text"}}
      assert check(specs, %{"s" => "  "}) == {:ok, %{}}
      assert messages(check(specs, %{"s" => %{"a" => "1"}})) == %{"s" => "is invalid"}
    end

    test "int" do
      specs = [spec("i", :int)]
      assert check(specs, %{"i" => "42"}) == {:ok, %{"i" => 42}}
      assert check(specs, %{"i" => ""}) == {:ok, %{}}
      assert messages(check(specs, %{"i" => "4.5"})) == %{"i" => "must be a whole number"}
    end

    test "number: an integer as written stays one, a fraction is a float" do
      specs = [spec("n", :number)]
      assert check(specs, %{"n" => "2"}) == {:ok, %{"n" => 2}}
      assert check(specs, %{"n" => "1.5"}) == {:ok, %{"n" => 1.5}}
      assert check(specs, %{"n" => "1e2"}) == {:ok, %{"n" => 100.0}}
      assert check(specs, %{"n" => ""}) == {:ok, %{}}
      assert messages(check(specs, %{"n" => "two"})) == %{"n" => "must be a number"}
    end

    test "bool" do
      specs = [spec("b", :bool)]
      assert check(specs, %{"b" => "true"}) == {:ok, %{"b" => true}}
      assert check(specs, %{"b" => "false"}) == {:ok, %{"b" => false}}
      assert check(specs, %{"b" => ""}) == {:ok, %{}}
      assert messages(check(specs, %{"b" => "maybe"})) == %{"b" => "must be true or false"}
    end

    test "enum answers the listed value, so a numeric enum keeps its type" do
      specs = [
        spec("e", :enum, %{values: [1, 2, 3]}),
        spec("a", :enum, %{values: [:none, :gzip]})
      ]

      assert check(specs, %{"e" => "2", "a" => "gzip"}) == {:ok, %{"e" => 2, "a" => :gzip}}
      assert check(specs, %{"e" => ""}) == {:ok, %{}}
      assert messages(check(specs, %{"e" => "4"})) == %{"e" => "must be one of 1, 2, 3"}
    end

    test "list splits on commas, trims and drops blanks" do
      specs = [spec("l", :list)]
      assert check(specs, %{"l" => " a, b ,,c "}) == {:ok, %{"l" => ["a", "b", "c"]}}
      assert check(specs, %{"l" => " , "}) == {:ok, %{}}
      assert messages(check(specs, %{"l" => ["a"]})) == %{"l" => "is invalid"}
    end

    test "object takes a JSON object only" do
      specs = [spec("o", :object)]
      assert check(specs, %{"o" => ~s({"x-test": "1"})}) == {:ok, %{"o" => %{"x-test" => "1"}}}
      assert check(specs, %{"o" => ""}) == {:ok, %{}}
      assert messages(check(specs, %{"o" => "[1, 2]"})) == %{"o" => "must be a JSON object"}
      assert messages(check(specs, %{"o" => "{nope"})) == %{"o" => "is not valid JSON"}
    end

    test "json takes any JSON value" do
      specs = [spec("j", :json)]
      assert check(specs, %{"j" => "[1, 2]"}) == {:ok, %{"j" => [1, 2]}}
      assert check(specs, %{"j" => ~s("text")}) == {:ok, %{"j" => "text"}}
      assert check(specs, %{"j" => " "}) == {:ok, %{}}
      assert messages(check(specs, %{"j" => "{nope"})) == %{"j" => "is not valid JSON"}
    end

    test "secret is text" do
      specs = [spec("k", :secret)]
      assert check(specs, %{"k" => "s3cret"}) == {:ok, %{"k" => "s3cret"}}
      assert check(specs, %{"k" => ""}) == {:ok, %{}}
    end
  end

  describe "requirement" do
    test "is checked only when asked for" do
      specs = [spec("url", :string, %{required: true}), spec("n", :int)]

      assert messages(check(specs, %{}, required?: true)) == %{"url" => "is required"}
      assert check(specs, %{}, required?: false) == {:ok, %{}}
      assert check(specs, %{}) == {:ok, %{}}
    end

    test "a required field already in error keeps its own error" do
      specs = [spec("o", :object, %{required: true})]

      assert messages(check(specs, %{"o" => "{nope"}, required?: true)) == %{
               "o" => "is not valid JSON"
             }
    end
  end

  describe "bounds" do
    test "min and max are stated with the bound" do
      specs = [spec("t", :int, %{min: 1, max: 60_000})]

      assert check(specs, %{"t" => "1"}) == {:ok, %{"t" => 1}}
      assert messages(check(specs, %{"t" => "0"})) == %{"t" => "must be at least 1"}
      assert messages(check(specs, %{"t" => "60001"})) == %{"t" => "must be at most 60000"}
    end

    test "are not read on a kind that is not a number" do
      assert check([spec("s", :string, %{min: 1})], %{"s" => "x"}) == {:ok, %{"s" => "x"}}
    end
  end

  test "several failing fields are reported at once, in field order" do
    specs = [
      spec("a", :int),
      spec("b", :string, %{required: true}),
      spec("c", :object)
    ]

    assert {:error, errors} = check(specs, %{"a" => "x", "c" => "[]"}, required?: true)
    assert Enum.map(errors, &elem(&1, 0)) == ["a", "b", "c"]
  end

  test "only the specs' own names are read from the params" do
    assert check([spec("a", :string)], %{"a" => "1", "f0" => "2", "other" => "3"}) ==
             {:ok, %{"a" => "1"}}
  end

  describe "typed_inputs/1" do
    import Phoenix.LiveViewTest

    defp render_inputs(specs, params \\ %{}, errors \\ []) do
      render_component(&TypedFields.typed_inputs/1,
        specs: specs,
        form: Phoenix.Component.to_form(params, as: "f", errors: errors),
        secret_name: "s",
        testid: "t-"
      )
    end

    test "a default is the placeholder, written for its kind" do
      html =
        render_inputs([
          spec("n", :int, %{default: 5}),
          spec("l", :list, %{default: ["a", :b, %{"c" => 1}]}),
          spec("o", :object, %{default: %{"x" => 1}}),
          spec("s", :string, %{default: %{"y" => 2}}),
          spec("j", :json, %{default: {:not, :json}})
        ])

      assert html =~ ~s(placeholder="5")
      assert html =~ ~s(placeholder="a, b, {&quot;c&quot;:1}")
      assert html =~ ~s(placeholder="{&quot;x&quot;:1}")
      assert html =~ ~s(placeholder="{&quot;y&quot;:2}")
      assert html =~ ~s(placeholder="{:not, :json}")
    end

    test "values and errors are read by name, and a secret is never filled" do
      html =
        render_inputs(
          [spec("a", :string), spec("k", :secret)],
          %{"a" => "given", "k" => "the-secret-value"},
          [{"a", {"must be at most %{number}", number: 3}}]
        )

      assert html =~ ~s(name="f[a]")
      assert html =~ ~s(value="given")
      assert html =~ "must be at most 3"
      assert html =~ ~s(name="s[k]")
      refute html =~ "the-secret-value"
    end
  end

  test "more specs than slots is :too_many" do
    specs = for i <- 1..129, do: spec("o#{i}", :string)

    refute TypedFields.fits?(specs)
    assert TypedFields.changeset(specs, %{}) == :too_many
    assert TypedFields.fits?(Enum.take(specs, 128))
  end

  test "names supplied from outside are never made atoms" do
    fresh = fn -> for _ <- 1..20, do: "never_seen_#{System.unique_integer([:positive])}" end
    specs = &Enum.map(&1, fn name -> spec(name, :string, %{required: true}) end)

    # Loads every module a check touches, so the count below measures names alone.
    warm = fresh.()
    check(specs.(warm), Map.new(warm, &{&1, "value"}), required?: true)
    check(specs.(warm), %{}, required?: true)

    names = fresh.()
    specs = specs.(names)
    params = Map.new(names, &{&1, "value"})

    before = :erlang.system_info(:atom_count)
    assert {:ok, values} = check(specs, params, required?: true)
    assert {:error, errors} = check(specs, %{}, required?: true)
    assert :erlang.system_info(:atom_count) == before

    assert Map.keys(values) |> Enum.sort() == Enum.sort(names)
    assert Enum.map(errors, &elem(&1, 0)) == names
  end
end
