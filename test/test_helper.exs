# A test that needs longer than this is waiting on time rather than on a
# condition it caused.
#
# A read a test awaits (`render_async/1`, `assert_receive`) answers as soon
# as it is done; the bound only decides how long a slow one may take before
# the test fails, so a busy machine is not mistaken for a broken read.
ExUnit.start(timeout: 5_000, assert_receive_timeout: 500)
Ecto.Adapters.SQL.Sandbox.mode(FlezhaConsole.Repo, :manual)
