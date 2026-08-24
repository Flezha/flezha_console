defmodule FlezhaUi.Accounts.EncryptedBinary do
  @moduledoc """
  An Ecto type for a secret this app must be able to read back but must never
  store in the clear — currently a user's flezha token.

  The key is derived from the endpoint's `secret_key_base`, which is supplied by
  the environment in production and is the one secret this app already requires
  callers to provide out-of-band. Rotating it makes stored tokens unreadable,
  which reads as "no token stored" and is recoverable by pasting the token
  again.
  """

  use Ecto.Type

  @salt "flezha_ui user flezha token v1"

  @impl true
  def type, do: :binary

  @impl true
  def cast(nil), do: {:ok, nil}
  def cast(value) when is_binary(value), do: {:ok, value}
  def cast(_value), do: :error

  @impl true
  def dump(nil), do: {:ok, nil}

  def dump(value) when is_binary(value) do
    {:ok, Plug.Crypto.MessageEncryptor.encrypt(value, key(), sign_key())}
  end

  def dump(_value), do: :error

  @impl true
  def load(nil), do: {:ok, nil}

  def load(value) when is_binary(value) do
    case Plug.Crypto.MessageEncryptor.decrypt(value, key(), sign_key()) do
      {:ok, plain} -> {:ok, plain}
      # An undecryptable value is a rotated key, not a corrupt row: answering
      # `nil` degrades to "no token stored" rather than failing every load.
      :error -> {:ok, nil}
    end
  end

  def load(_value), do: :error

  @impl true
  def embed_as(_format), do: :self

  @impl true
  def equal?(a, b), do: a == b

  defp key, do: derive("enc")
  defp sign_key, do: derive("sign")

  defp derive(purpose) do
    Plug.Crypto.KeyGenerator.generate(secret_key_base(), @salt <> " " <> purpose, length: 32)
  end

  defp secret_key_base do
    :flezha_ui
    |> Application.fetch_env!(FlezhaUiWeb.Endpoint)
    |> Keyword.fetch!(:secret_key_base)
  end
end
