# Fallback SDK
## Overview

Antithesis provides a variety of language-native SDKs, which are recommended for integrating with Antithesis. However, you might be unable to use any of these libraries, either for policy reasons or because one has not yet been implemented in your language of choice. In this case, Antithesis enables you to access nearly all SDK functionality by logging low-level JSONL messages to a special location.

As [part of the Antithesis environment](/docs/configuration/the_antithesis_environment/#capturing-output), Antithesis modifies your software's container environment by injecting the variable `ANTITHESIS_OUTPUT_DIR`, which points to a directory. Antithesis watches this directory and captures any output written to it. This directory contains in particular the special file location `$ANTITHESIS_OUTPUT_DIR/sdk.jsonl`, or the *SDK capture file*. Antithesis interprets the SDK capture file as a source of SDK messages.

When JSONL messages are written to this file, Antithesis will ingest these messages and use SDK functionality as if SDK functions had been invoked inline. Each message must be written atomically as a [JSONL object](https://jsonlines.org/): a single line of JSON terminating with a newline character.

> **Important**
>
> You must emit JSONL messages. Each individual message must be a single line of JSON that terminates in a newline character. However, the examples show JSON messages spread across multiple lines purely for readability. This will not work in practice. Each message must be a single line.

### SDK functionality: fallback options

Antithesis SDKs provide three types of functionality:

- **Assertions**, which define [test properties](/docs/introduction/how_antithesis_works/#how-does-antithesis-identify-bugs) through writing assertions inline in your code. If you cannot use our SDKs, you can still use our assertions framework. This requires emitting [assertion JSONL messages](/docs/reference/sdk/fallback/assert/) to the SDK capture file.

  These assertions will be recognized by our platform, which will evaluate the assertions and record the results in our reports.

- **Lifecycle**, which indicates that certain milestones in program setup and execution have been reached. If you cannot use our SDK, you can still indicate these milestones. This requires emitting [lifecycle JSONL messages](/docs/reference/sdk/fallback/lifecycle/) to the SDK capture file.

- **Randomness**, which requests structured and unstructured randomness from the Antithesis platform. If you cannot use our SDK, you may [read from the system random devices](/docs/configuration/the_antithesis_environment/#random-devices). You should not use your language's PRNG. The SDKs are preferable -- these indicate to Antithesis the purpose of your randomness, which enables more intelligent exploration of code.

### Instrumentation

Antithesis instrumentation is compatible with most languages that use LLVM for code generation. If you wish to enable instrumentation for an LLVM-based language that is not on our currently supported list, please contact us for advice.
