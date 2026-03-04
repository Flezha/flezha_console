defmodule FlezhaUi.Repo do
  use Ecto.Repo,
    otp_app: :flezha_ui,
    adapter: Ecto.Adapters.Postgres
end
