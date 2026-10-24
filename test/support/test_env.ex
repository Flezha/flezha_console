defmodule FlezhaConsole.TestEnv do
  @moduledoc """
  Changes a test makes to the VM's environment, each undone when the test
  ends. The environment is global to the VM, so only a serial test uses these.

  A value of `nil` unsets the key. Each call restores what it found, and
  `on_exit/1` runs its callbacks last-registered first, so a test that changes
  one key several times leaves it as it was before the first.
  """

  import ExUnit.Callbacks, only: [on_exit: 1]

  @doc "Sets the application's `key` to `value` for the rest of the test."
  def put_app(key, value) do
    swap(
      Application.fetch_env(:flezha_console, key),
      value,
      &Application.put_env(:flezha_console, key, &1),
      fn -> Application.delete_env(:flezha_console, key) end
    )
  end

  @doc "Sets the OS environment variable `name` to `value` for the rest of the test."
  def put_system(name, value) do
    swap(System.fetch_env(name), value, &System.put_env(name, &1), fn ->
      System.delete_env(name)
    end)
  end

  defp swap(previous, value, put, delete) do
    on_exit(fn -> apply_value(previous, put, delete) end)
    apply_value(if(is_nil(value), do: :error, else: {:ok, value}), put, delete)
  end

  defp apply_value({:ok, value}, put, _delete), do: put.(value)
  defp apply_value(:error, _put, delete), do: delete.()
end
