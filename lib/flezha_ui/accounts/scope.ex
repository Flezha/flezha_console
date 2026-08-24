defmodule FlezhaUi.Accounts.Scope do
  @moduledoc """
  Defines the scope of the caller to be used throughout the app.

  The `FlezhaUi.Accounts.Scope` allows public interfaces to receive
  information about the caller, such as if the call is initiated from an
  end-user, and if so, which user. Additionally, such a scope can carry fields
  such as "super user" or other privileges for use as authorization, or to
  ensure specific code paths can only be access for a given scope.

  It is useful for logging as well as for scoping pubsub subscriptions and
  broadcasts when a caller subscribes to an interface or performs a particular
  action.

  Feel free to extend the fields on this struct to fit the needs of
  growing application requirements.
  """

  alias FlezhaUi.Accounts.User

  @derive {Inspect, except: [:flezha_token]}
  defstruct user: nil, flezha_token: nil

  @doc """
  Creates a scope for the given user.

  The scope carries the flezha token this caller presents to the controller,
  resolved once here rather than per remote call: `FlezhaUi.Accounts` owns the
  precedence between a user's own token and the service token.

  Returns nil if no user is given.
  """
  def for_user(%User{} = user) do
    %__MODULE__{user: user, flezha_token: FlezhaUi.Accounts.flezha_token(user)}
  end

  def for_user(nil), do: nil

  @doc """
  The flezha token a scope presents, or the service token when there is no
  scope at all — a controller-rendered page outside a session still identifies
  the app.
  """
  def flezha_token(%__MODULE__{flezha_token: token}), do: token
  def flezha_token(_scope), do: FlezhaUi.Accounts.service_flezha_token()
end
