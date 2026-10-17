# Assertion catalog
In [any given execution history](/docs/product/debugging/advanced_multiverse_debugging/moment_branch/), Antithesis may not encounter every assertion you make. Since many types of assertions are supposed to fail if they're never reached, Antithesis must be informed that these assertions exist so it can mark them as failing when this happens.

An assertion catalog lists every [assertion](/docs/product/writing_tests/assertions/) you add to your code.

We add a small amount of additional code, which runs at startup, that creates a catalog of assertions. This code is only run once at startup, so it has minimal performance impact.

The way we do this is a little different for every language, but each way produces a common output formatting, enabling us to provide unified reporting across your entire architecture.
