# Coverage instrumentation
Coverage instrumentation tells Antithesis which lines of code are reached over the course of testing. When you instrument the system under test, the coverage callbacks at every basic block in the program's control flow enables Antithesis to explore it effectively.

For some languages, instrumentation is *required* to define test properties, consult the language-specific documentation for more details.

When you instrument your code, you may need to install additional runtime dependencies into your containers, but the benefits are well worth it.

> **Warning**
>
> Coverage instrumentation has a higher overhead than other SDK functions. We do not recommend running binaries with coverage instrumentation in production.

## Benefits of instrumentation

When run in Antithesis, instrumentation provides the following benefits:

- Instrumentation sends continuous feedback to Antithesis, which enables it to find bugs faster and more reliably.
- Instrumentation enables a powerful fault-injection technique called [thread pausing](/docs/product/writing_tests/controlling_faults/fault_types/#thread-pausing) which is useful for finding subtle race conditions and other concurrency bugs.
- Instrumentation provides much richer data to the [bug report](/docs/product/understanding_test_results/reports/), allowing us to automatically discover which lines of code were most and least associated with the bug.

## Supported languages

The following is a list of languages that are supported for instrumentation.

- [Go instrumentation](/docs/reference/sdk/go/instrumentation/)
- [C/C++ instrumentation](/docs/reference/sdk/cpp/instrumentation/)
- [Java instrumentation](/docs/reference/sdk/java/how_to_build_with_sdk/#enable-coverage-instrumentation)
- [JavaScript instrumentation](/docs/reference/sdk/javascript_sdk/)
- [Rust instrumentation](/docs/reference/sdk/rust/instrumentation/)
- [.NET instrumentation](/docs/reference/sdk/dotnet/instrumentation/)
- [Other LLVM instrumentation](/docs/reference/sdk/fallback/#instrumentation)

If your language is not on this list, it may still be possible to enable instrumentation. For more details, contact us at [support@antithesis.com](mailto:support@antithesis.com) or [ask on our Discord](https://discord.com/invite/antithesis).

## Symbolization

Symbolization is the process of translating between locations in your compiled code and locations in your source files. For some languages, Antithesis handles all of this automatically. For other languages, you might need to compile with specific flags, or have your build/CI system put symbol files into a specific location in order for symbolization to work.

If your code includes coverage instrumentation (whether from an Antithesis instrumentor or the language compiler) Antithesis expects a symbol catalog for every instrumented module that loads during a test. A module that loads without one fails the `Every instrumented module has symbols` property in the [triage report](/docs/product/understanding_test_results/reports/)'s Setup group, which names the module to fix.

Please consult the language-specific documentation for detailed instructions on enabling symbolization.

Symbols are placed in the image containing the instrumented software. Antithesis will search the root of every container image you push for a directory named `/symbols` and automatically extract any symbol files it finds there. When searching for symbol files, Antithesis will follow symlinks, so you can place a symlink in the `/symbols` directory instead of a symbol file, which you might want to do if, for instance, your symbols are normally part of the same binary as your code.

For compiler-instrumented binaries, either place or symlink the unstripped binary, or the stripped binary alongside its debug info, into the /symbols directory.

## Validation

You can confirm that the instrumentation process worked correctly by looking at your [triage report](/docs/product/understanding_test_results/reports/).

Under the `Setup` property group, there is a [default property](/docs/product/understanding_test_results/reports/properties/) called `Software was instrumented`. If this property is passing, then your code was instrumented and loaded during the test. Each example listed under this property is a different binary, program, or module that was instrumented. The details section for the examples lists the name of the module, its language, the number of locations within it that were instrumented, and whether a symbol catalog was available for it. A module without a catalog also fails the `Every instrumented module has symbols` property next to it.

## Link-time optimization

Compiler-based instrumentation (C/C++ and Rust) inserts the coverage callbacks into each compilation unit as it is compiled. If link-time optimization then runs over the program, the optimizer inlines, merges, and tail-calls the instrumented code, and Antithesis can no longer map what the binary reports back to your source. Such a build reports the binary's symbol catalog as incomplete and ships no symbols for it.

Builds that use link-time optimization must instrument at link time instead, which both languages support: see [C/C++](/docs/reference/sdk/cpp/instrumentation/#link-time-optimization) and [Rust](/docs/reference/sdk/rust/instrumentation/#link-time-optimization).

## Shared libraries

Antithesis supports instrumentation of shared or dynamic dependencies of your program. This works even if the main program is *not* instrumented, and even if the dynamic dependency is loaded after process start with `dlopen`.

> **Warning**
>
> Instrumented shared libraries must stay loaded for the lifetime of your process. If something in your program insists on calling `dlclose`, then you should load instrumented libraries with the `RTLD_NODELETE` flag so that the library stays resident.
