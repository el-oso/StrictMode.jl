using StrictMode
using ReTestItems

# Tests run with checks_enabled=true (see test/LocalPreferences.toml) so the failing-path items
# actually exercise the guarantees.
runtests(StrictMode)
