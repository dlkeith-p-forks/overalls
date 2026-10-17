# Test commands
This page explains the types of test commands available in Antithesis. Test commands must be placed in [test templates](/docs/product/writing_tests/test_templates/).

Many users choose to get started by taking an existing integration test and running it in Antithesis using a [singleton driver command](/docs/product/writing_tests/test_templates/test_composer_reference/#singleton-driver-command).

## What's a test command?

A **test command** is an executable file that exercises the system under test. It must:

- Live in a test template, e.g. `/opt/antithesis/test/v1/<test_template>/<prefix>_<command>`.
- Have a filename starting with a recognized `<prefix>`. The `<prefix>` determines *when* and *how* the command runs. `<command>` can be any valid Unix filename, with any or no extension.
- Be marked executable by the container's default user.
- Be a compiled binary or have a shebang, e.g. `#!/usr/bin/env bash`, `#!/usr/bin/env python3` if it's a script.

If you're using an existing script as a test command, you can simply put a symlink in the test directory.

```shell
ln /path/to/existingscript /opt/antithesis/test/v1/<test_name>/<prefix>_<command>
```

Antithesis handles all selection and scheduling of test commands during a run.

> **Note**
>
> Some test commands stop fault injection. See details under each command.

## Types of test commands

Antithesis provides 7 types of test commands.

A test template must have *at least one* of the following test commands:

- `parallel_driver`
- `singleton_driver`
- `serial_driver`
- `anytime`

**First command**

Prefix: `first_`, e.g. `<test_template>/first_<command>`

`first` commands run one-time setup logic. Some test strategies benefit from using a `first` command to, e.g. create schemas or seed initial test data in a database.

##### Scheduling rules

- A `first` command runs *after* `setup_complete` but *before* any other commands start.
- If a test template contains any `first` commands, a `first` command will run in every timeline using that template.
- If a test template contains multiple `first` commands, **exactly one** is selected per timeline.
- `First` commands run to completion before any faults or other commands start.
- Don't emit `setup_complete` from a `first` command. The `first` command only runs *after* `setup_complete`.

##### Fault injection

No faults are injected during the execution of a `first` command.

##### Concurrency

No other commands run alongside a `first` command.

**Parallel driver command**

Prefix: `parallel_driver_`, e.g. `<test_template>/parallel_driver_<command>`

`parallel_driver` commands are the core of most Antithesis tests. Use them for tasks that can run concurrently, like writes, reads, transactions, and API calls.

##### Scheduling rules

- `parallel_driver` commands run at any point after the `first` command (if any) completes.
- If the test template doesn't contain any `first` commands, `parallel_driver`commands can run immediately after `setup_complete`.
- Multiple `parallel_driver` commands can run **simultaneously**, including multiple copies of the same command.

##### Fault injection

Faults are injected as normal, including mid-execution.

##### Concurrency

One or more `parallel_driver` or `anytime` commands can run alongside.

##### Usage

`parallel_driver` and `serial_driver` commands are the core of most Antithesis tests and most of your test templates should contain one or more of them.

**Serial driver command**

Prefix: `serial_driver_`, e.g. `<test_template>/serial_driver_<command>`

Use `serial_driver` commands for operations that cannot run concurrently and need exclusive access to the system. No other commands, except `anytime`, can run concurrently.

##### Scheduling rules

- `serial_driver` commands can run at any point after the `first` command (if any) completes.
- If the test template doesn't contain any `first` commands, `serial_driver` commands can run immediately after `setup_complete`.

##### Fault injection

Faults are injected as normal, including mid-execution.

##### Concurrency

One or more `anytime` commands can run alongside.

##### Usage

`serial_driver` and `parallel_driver` commands are the core of most Antithesis tests and most of your test templates should contain one or more of them.

**Singleton driver command**

Prefix: `singleton_driver_`, e.g. `<test_template>/singleton_driver_<command>`

`Singleton_driver` commands *only run once on a given timeline.* Use them for operations that cannot run concurrently and need exclusive access to the system.

##### Scheduling rules

- `Singleton_driver` commands can run at any point after the `first` command (if any) completes.
- If the test template doesn't contain any `first` commands, a `singleton_driver` can run immediately after `setup_complete`.
- `Serial_driver` and `parallel_driver` commands will not be run on the same timeline before or after a `singleton_driver`.
- Exactly one `singleton_driver` is run per timeline.

##### Fault injection

Faults are injected as normal, including mid-execution.

##### Concurrency

One or more `anytime` commands can run alongside.

##### Usage

- Porting an existing integration test to Antithesis.
- Running a monolithic workload that handles parallelism internally.
- Quick proof-of-concept testing for new workloads.

**Anytime command**

Prefix: `anytime_`, e.g. `<test_template>/anytime_<command>`

Use `anytime` commands to check invariants that should always hold, regardless of what else is happening in the system or environment.

##### Scheduling rules

- `Anytime` commands can run at any time after the `first` command, including during `singleton_driver`, `serial_driver`, and `parallel_driver` execution.
- `Anytime` commands will **not** run while a `finally` or `eventually` command is running.

##### Fault injection

Faults are injected as normal, including mid-execution.

##### Concurrency

`Serial_driver`, `parallel_driver`, and `singleton_driver` commands can run alongside `anytime` commands.

##### Usage

- Continuous invariant checks: "a read always reflects the previous write".
- Availability monitoring: "it's possible to make a read without timing out".

**Eventually command**

Prefix: `eventually_`, e.g. `<test_template>/eventually_<command>`

`Eventually` commands check system recovery and eventually true invariants. When an `eventually` command starts, Antithesis **kills all other running commands** and stops all fault injection.

Although faults stop immediately, it can take some time for containers to become operational again. `Eventually` commands should include **retry loops and health checks** to ensure the system has time to recover.

Antithesis won't resume testing on this timeline, so `eventually` commands can include destructive actions (e.g. drop tables, kill processes).

`Eventually` and `finally` commands are often confused. [The table below](/docs/product/writing_tests/test_templates/test_composer_reference/#eventually-vs-finally) clarifies the differences.

##### Scheduling rules

- `Eventually` commands run **only** after at least one `parallel_driver`, `serial_driver`, or `singleton_driver` has started.
- You should not assume `eventually` commands will run on every timeline.

##### Fault injection

All faults stop across all containers when an `eventually` command starts.

Although faults stop immediately, it can take some time for containers to become operational again. `eventually` commands should include **retry loops and health checks** to ensure the system has time to recover.

##### Concurrency

No other commands run alongside an `eventually` command.

##### Usage

`Eventually` commands should be used to check that the system eventually recovers.

- Verifying eventual properties: [availability](/docs/resources/reliability_glossary/#availability-models), [consistency](/docs/resources/reliability_glossary/#consistency-models), convergence.
- Checking that the system recovers after faults.
- Any verification that requires a quiet system (no concurrent writes or faults).

**Finally command**

Prefix: `finally_`, e.g. `<test_template>/finally_<command>`

`Finally` commands check system recovery and eventually true invariants.

Unlike `eventually` commands, `finally` commands only run in timelines where **every command started has run to completion** and not been killed by a fault or another command.

Although faults stop immediately, it can take some time for containers to become operational again. `Finally` commands should include **retry loops and health checks** to ensure the system has time to recover.

Antithesis won't resume testing on this timeline, so `finally` commands can include destructive actions (e.g. drop tables, kill processes).

`Finally` and `eventually` commands are easily confused. [This table](/docs/product/writing_tests/test_templates/test_composer_reference/#eventually-vs-finally) clarifies the differences.

##### Scheduling rules

- Finally commands run **only** after at least one  `parallel_driver`, `serial_driver`, or `singleton_driver` has run to completion.
- You should not assume `finally` commands will run on every timeline.

##### Fault injection

All faults stop across all containers when a `finally` command starts.

Although faults stop immediately, it can take some time for containers to become operational again. `finally` commands should include **retry loops and health checks** to ensure the system has time to recover.

##### Concurrency

No other commands run alongside a `finally` command.

##### Usage

`Finally` commands should be used to check that the final system state is correct.

- "The database contains exactly N rows" (only meaningful if the commands that wrote them finished).
- "All expected data is present" (requires drivers to have completed their writes).
- Final consistency checks that assume a complete workload.

**eventually vs. finally**

| | `eventually` | `finally` |
|---|---|---|
| Use case | "Does the system recover?" | "Is the final state correct?" |
| When it runs | After at least one driver has started. | After all started drivers have completed naturally. |
| How drivers end | Killed by Antithesis. | Completed on their own. |
| Faults | Stopped. | Stopped. |
| Destructive actions? | Yes — branch won't resume. | Yes — branch won't resume. |

## Summary

| Command type | Prefix | Faults active? | Which commands can run alongside? |
|---|---|---|---|
| first | `first_` | No | None. |
| parallel\_driver | `parallel_driver_` | Yes | One or more `parallel_driver` or  `anytime`. |
| serial\_driver | `serial_driver_` | Yes | One or more `anytime`. |
| singleton\_driver | `singleton_driver_` | Yes | One or more `anytime`. |
| eventually | `eventually_` | No | None. |
| finally | `finally_` | No | None. |
| anytime | `anytime_` | Yes (during drivers) | Any except `first`. |

Here's an illustration of how the various test commands could be scheduled during a test run.

## Further reading

For a more detailed explanation of the concepts underpinning the test templates, see [best practices for autonomous testing](/docs/resources/autonomous_testing/).

For guidance on how to test each of these commands locally before deploying to Antithesis, see [checking test templates locally](/docs/product/writing_tests/test_templates/testing_locally/).

For an example of how to convert an existing integration test into a test template, check out [this example](/docs/product/writing_tests/test_templates/composer_example/), using Turso's actual test setup.
