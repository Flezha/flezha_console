# A test that needs longer than this is waiting on time rather than on a
# condition it caused.
ExUnit.start(timeout: 5_000)
Ecto.Adapters.SQL.Sandbox.mode(FlezhaUi.Repo, :manual)
