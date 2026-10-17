# Compose a runNixOSTest test module with Hegel property-based testing.
#
# Usage in a machine test:
#
#   hegel.runTest {
#     name = "my-service";
#     properties = { enable = true; profile = "ci"; redact = false; testCases = 25; statefulStepCount = 40; };
#     nodes.machine = { ... };
#     testScript = ''
#       from hegel import given, integers, _run_registered  # epilogue calls it
#       @given(n=integers())
#       def property(tc, n): ...
#     '';
#   }
#
# The wrapper composes the user testScript with a prologue (the hegel import,
# which also satisfies ty/ruff on the composed driver) and an epilogue that
# executes every registered property. All other runNixOSTest options pass
# through unchanged; `properties` itself is consumed here and never reaches
# the upstream nixosTest module class.
{
  pkgs,
  hegelPython,
}:
let
  inherit (pkgs) lib;

  defaults = {
    enable = false;
    profile = "ci";
    testCases = 25;
    statefulStepCount = 40;
    seed = null;
    derandomize = null;
    database = null;
    redact = false;
    verbosity = "normal";
    phases = null;
  };

  none = "None";
  pyBool = value: if value == null then none else if value then "True" else "False";
  pyInt = value: if value == null then none else toString value;
  pyStr = value: if value == null then none else builtins.toJSON value;
  pyStrList =
    value: if value == null then none else "(${lib.concatMapStringsSep "," (v: builtins.toJSON v) value},)";

  # Appended after the user's script so registrations happen first.
  epilogue = cfg: ''
    from hegel import _run_registered as _overalls_hegel_run
    _overalls_hegel_run(
        profile=${pyStr cfg.profile},
        test_cases=${pyInt cfg.testCases},
        seed=${pyInt cfg.seed},
        derandomize=${pyBool cfg.derandomize},
        database=${pyStr cfg.database},
        stateful_step_count=${pyInt cfg.statefulStepCount},
        verbosity=${pyStr cfg.verbosity},
        redact=${pyBool cfg.redact},
        phases=${pyStrList cfg.phases},
    )
  '';
in
{
  # @cc [owner:ghuntley,label:verification] hegel-test-properties-execution
  # Tests opting into `properties` MUST actually execute registered Hegel
  # properties; the appended epilogue runs them and fails the test on a
  # counterexample.
  runTest =
    {
      properties ? { },
      testScript ? "",
      extraPythonPackages ? (_ps: [ ]),
      ...
    }@test:
    let
      cfg = defaults // properties;
      hasProperties = cfg.enable;

      composedScript =
        if lib.isFunction testScript then
          args: testScript args + lib.optionalString hasProperties ("\n" + epilogue cfg)
        else
          testScript + lib.optionalString hasProperties ("\n" + epilogue cfg);
    in
    pkgs.testers.runNixOSTest (
      (removeAttrs test [ "properties" ])
      // {
        testScript = composedScript;
        extraPythonPackages =
          ps: (extraPythonPackages ps) ++ lib.optionals hasProperties [ hegelPython ];
        passthru =
          (test.passthru or { })
          // lib.optionalAttrs hasProperties {
            hegel = {
              inherit cfg;
              python = hegelPython;
            };
          };
      }
    );
}
