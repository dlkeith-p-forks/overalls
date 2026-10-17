# Unit and harness-adapter tests model a root-run Lilly that connects to local
# sockets directly. A deployed unprivileged Lilly host (ADR-0182) may export
# LILLY_SERVICE_UID into every login session; inheriting it would route local
# connects through an absent lilly-hostd and make socket tests fail by timeout.
# Clear both the variable and Lilly.Host.Privilege's read-once cache so the
# suite is hermetic against the developer machine's deployment environment.
System.delete_env("LILLY_SERVICE_UID")
:persistent_term.erase({Lilly.Host.Privilege, :service_uid})

ExUnit.start(formatters: [ExUnit.CLIFormatter, Covenant.Formatter])
