defmodule FlezhaUiWeb.UserSessionHTML do
  use FlezhaUiWeb, :html

  embed_templates "user_session_html/*"

  defp local_mail_adapter? do
    Application.get_env(:flezha_ui, FlezhaUi.Mailer)[:adapter] == Swoosh.Adapters.Local
  end
end
