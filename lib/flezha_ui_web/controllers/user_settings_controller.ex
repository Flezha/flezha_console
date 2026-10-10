defmodule FlezhaUiWeb.UserSettingsController do
  use FlezhaUiWeb, :controller

  alias FlezhaUi.Accounts
  alias FlezhaUi.Service.NodeManager
  alias FlezhaUiWeb.UserAuth

  import FlezhaUiWeb.UserAuth, only: [require_sudo_mode: 2]

  plug :require_sudo_mode
  plug :assign_settings_state

  def edit(conn, _params) do
    render(conn, :edit)
  end

  def update(conn, %{"action" => "update_email"} = params) do
    %{"user" => user_params} = params
    user = conn.assigns.current_scope.user

    case Accounts.change_user_email(user, user_params) do
      %{valid?: true} = changeset ->
        Accounts.deliver_user_update_email_instructions(
          Ecto.Changeset.apply_action!(changeset, :insert),
          user.email,
          &url(~p"/users/settings/confirm-email/#{&1}")
        )

        conn
        |> put_flash(
          :info,
          "A link to confirm your email change has been sent to the new address."
        )
        |> redirect(to: ~p"/users/settings")

      changeset ->
        render(conn, :edit, email_changeset: %{changeset | action: :insert})
    end
  end

  def update(conn, %{"action" => "update_password"} = params) do
    %{"user" => user_params} = params
    user = conn.assigns.current_scope.user

    case Accounts.update_user_password(user, user_params) do
      {:ok, {user, _}} ->
        conn
        |> put_flash(:info, "Password updated successfully.")
        |> put_session(:user_return_to, ~p"/users/settings")
        |> UserAuth.log_in_user(user)

      {:error, changeset} ->
        render(conn, :edit, password_changeset: changeset)
    end
  end

  def update(conn, %{"action" => "update_flezha_token", "flezha_token" => %{"token" => token}}) do
    user = conn.assigns.current_scope.user
    previous = Accounts.user_flezha_token(user)

    case Accounts.update_user_flezha_token(user, token) do
      {:ok, _user} ->
        # Both ends: the replaced token must stop answering from cache, and the
        # new one must be verified now rather than reported from a stale entry.
        previous && NodeManager.evict_token(previous)
        NodeManager.evict_token(String.trim(token))

        conn
        |> put_flash(:info, flezha_token_flash(token))
        |> redirect(to: ~p"/users/settings")

      {:error, _changeset} ->
        conn
        |> put_flash(:error, "Could not store the flezha token.")
        |> redirect(to: ~p"/users/settings")
    end
  end

  # Offered only while the bootstrap is pending: a claim made later is core's
  # break-glass recovery, which unbinds the existing admin. The minted admin
  # token becomes the user's own through the encrypted path a pasted token
  # takes, and is never rendered.
  def update(conn, %{"action" => "claim_bootstrap", "bootstrap" => %{"token" => bootstrap_token}}) do
    user = conn.assigns.current_scope.user

    with :bootstrap_pending <- conn.assigns.authz.posture,
         {:ok, %{principal: principal} = claimed} <-
           NodeManager.bootstrap(String.trim(bootstrap_token), nil) do
      store_minted(user, claimed[:minted_token])

      conn
      |> put_flash(:info, claimed_flash(principal, claimed[:minted_token]))
      |> redirect(to: ~p"/users/settings")
    else
      {:error, reason} ->
        render(conn, :edit, bootstrap_error: reason)

      _posture ->
        conn
        |> put_flash(:error, "No bootstrap is pending on the controller.")
        |> redirect(to: ~p"/users/settings")
    end
  end

  def update(conn, %{"action" => "clear_flezha_token"}) do
    user = conn.assigns.current_scope.user
    previous = Accounts.user_flezha_token(user)

    {:ok, _user} = Accounts.clear_user_flezha_token(user)
    previous && NodeManager.evict_token(previous)

    conn
    |> put_flash(:info, "Flezha token cleared. This UI falls back to its service token.")
    |> redirect(to: ~p"/users/settings")
  end

  def confirm_email(conn, %{"token" => token}) do
    case Accounts.update_user_email(conn.assigns.current_scope.user, token) do
      {:ok, _user} ->
        conn
        |> put_flash(:info, "Email changed successfully.")
        |> redirect(to: ~p"/users/settings")

      {:error, _} ->
        conn
        |> put_flash(:error, "Email change link is invalid or it has expired.")
        |> redirect(to: ~p"/users/settings")
    end
  end

  # The token changeset has no validations, so storing answers `{:ok, _}`.
  defp store_minted(user, minted) when is_binary(minted) do
    previous = Accounts.user_flezha_token(user)
    {:ok, _user} = Accounts.update_user_flezha_token(user, minted)
    previous && NodeManager.evict_token(previous)
    NodeManager.evict_token(minted)
  end

  defp store_minted(_user, _minted), do: :ok

  defp claimed_flash(principal, minted) when is_binary(minted),
    do: "Bootstrap claimed: #{principal} is bound as admin@_system, and its token is now yours."

  defp claimed_flash(principal, _minted),
    do: "Bootstrap claimed: #{principal} is bound as admin@_system. No token was minted for it."

  # What binds is the effective token, which may be the service token; whether
  # the *user* stored one is a separate fact, and the screen states both. The
  # token value itself is never assigned.
  defp assign_settings_state(conn, _opts) do
    user = conn.assigns.current_scope.user

    conn
    |> assign(:email_changeset, Accounts.change_user_email(user))
    |> assign(:password_changeset, Accounts.change_user_password(user))
    |> assign(:user_token_stored?, Accounts.user_flezha_token(user) != nil)
    |> assign(:authz, NodeManager.authz_status(Accounts.flezha_token(user)))
    |> assign(:bootstrap_error, nil)
  end

  # Stated from the verification, so an operator learns immediately that the
  # token they pasted is expired rather than on the next refused screen.
  defp flezha_token_flash(token) do
    case NodeManager.verify_token(String.trim(token)) do
      {:ok, %{principal: principal, namespace: namespace, role: role}} ->
        "Flezha token stored. Calls are now made as #{principal} (#{namespace}, #{role})."

      {:error, :no_token} ->
        "Flezha token cleared. This UI falls back to its service token."

      {:error, reason} ->
        %{message: message, code: code} = NodeManager.error(reason)
        "Flezha token stored, but it did not verify: #{message} (#{code})."
    end
  end
end
