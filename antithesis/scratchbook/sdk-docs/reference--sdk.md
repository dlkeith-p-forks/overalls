# SDKs
Antithesis SDKs are the most straightforward way to integrate Antithesis in your development lifecycle, and define properties for your Antithesis tests.

Antithesis offers SDKs in a number of popular languages:

- [Go](/docs/reference/sdk/go/)
- [Java](/docs/reference/sdk/java/)
- [C](/docs/reference/sdk/c_sdk/)
- [C++](/docs/reference/sdk/cpp/)
- [JavaScript](/docs/reference/sdk/javascript_sdk/)
- [Python](/docs/reference/sdk/python/)
- [Rust](/docs/reference/sdk/rust/)
- [.NET](/docs/reference/sdk/dotnet/)

If you cannot use our SDK, either due to policy, or because we have not yet produced an SDK in your language of choice, Antithesis offers a low-level fallback API.

## SDK runtime modes

All our SDKs can run safely in production with minimal impact on your software's performance.

To do this, the SDKs detect at startup time whether the program is running in the Antithesis Environment. If not, then their functions turn into no-ops, or log statements, or shims to appropriate standard library functions. SDK functions that turn into no-ops when run in production will still evaluate their arguments, so that `antithesis_foo(function_with_vital_side_effects())` doesn't become a bug.

However, if you have ultra-high performance software dependent on split-second timing, most of our SDKs provide ways to completely disable them at build time. The details of how this works differ a little bit from language to language; consult the language-specific SDK documentation for more information.

## Functionality

Our SDKs offer three main categories of functionality:

- [Define test properties](/docs/reference/sdk/define_test_properties/)
- [Generate randomness](/docs/reference/sdk/generate_randomness/)
- [Manage test lifecycle](/docs/reference/sdk/manage_test_lifecycle/)

Additionally, they enable:

- **Assertion cataloging** -- required to use SDK assertions.
- **Coverage instrumentation** -- tracks code coverage as your software runs in Antithesis.

These functions are only relevant if you're using the SDKs to define test properties, but they're essential if you do so.
