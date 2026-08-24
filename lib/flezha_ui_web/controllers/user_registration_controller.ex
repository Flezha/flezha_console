defmodule FlezhaUiWeb.UserRegistrationController do
  use FlezhaUiWeb, :controller

  # These screens render `<Layouts.auth>` themselves — a centred panel on the
  # bare canvas. Without this they would also be wrapped in the console shell.
  plug :put_layout, html: false

  alias FlezhaUi.Accounts
  alias FlezhaUi.Accounts.User

  def new(conn, _params) do
    changeset = Accounts.change_user_email(%User{})
    render(conn, :new, changeset: changeset)
  end

  def create(conn, %{"user" => user_params}) do
    case Accounts.register_user(user_params) do
      {:ok, user} ->
        {:ok, _} =
          Accounts.deliver_login_instructions(
            user,
            &url(~p"/users/log-in/#{&1}")
          )

        conn
        |> put_flash(
          :info,
          "An email was sent to #{user.email}, please access it to confirm your account."
        )
        |> redirect(to: ~p"/users/log-in")

      {:error, %Ecto.Changeset{} = changeset} ->
        render(conn, :new, changeset: changeset)
    end
  end
end
