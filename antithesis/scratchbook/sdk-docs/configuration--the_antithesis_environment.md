# The Antithesis environment
Antithesis deploys your containerized software in a controlled and deterministic simulation environment, the **Antithesis environment**.

Your software is packaged in Linux containers, so you have almost total control over the userspace within which your software runs. However, Antithesis controls the following features of the environment it runs in:

- The [machine environment](#the-machine-environment): the machine that hosts your containers.
- The [container environment](#the-container-environment): we inject special device drivers, file and directory mounts, and environment settings into your containers at runtime, to help your software integrate with the Antithesis platform more easily. This also allows you to [detect](#detecting-whether-you-are-running-within-antithesis) whether your software is running within Antithesis.

## The machine environment

This section describes the machine that hosts your containers.

### Operating system

Your containers will be installed and run on a kernel that's optimized to find bugs. It's mostly a Linux-6.x kernel with io\_uring support. If you need a different minor version, we can usually accommodate that very easily. If you need to bring your own kernel, we support that too, but there may be some performance degradation. Contact us at support@antithesis.com and we can change the default kernel for some or all of your tests.

### CPU

Your machine runs a simulated Intel CPU with an x86-64 instruction set and most extensions present on the Skylake architecture (see [here](/docs/configuration/cpuid/) for an exact list of feature flags). Your code must be compiled for x86-64, and we do not currently offer alternative CPU architectures. Nested hardware virtualization is not supported at this time -- if you wish to run your own hypervisor within Antithesis, it must use software emulation.

The default clock speed of this simulated CPU is configurable, but unless you tell us otherwise we will occasionally modulate or "strobe" the CPU speed as a form of [fault injection](/docs/product/writing_tests/controlling_faults/). By default, the CPU is divided evenly amongst your containers, and any of them may use up to 100% of the CPU if the rest of the system is idle. At times during testing, we may limit the share of CPU available to one or more containers, in order to simulate particular services becoming overloaded or unresponsive.

The Antithesis simulation can "fast-forward" through periods of time when the system is idle. Code that follows a [race-to-sleep](https://en.wikichip.org/wiki/race-to-sleep) pattern will perform much better than code that busy-waits. We offer [diagnostic properties](/docs/best_practices/optimizing/#monitor-simulation-efficiency) to help identify whether your code is taking advantage of this capability. Certain operations, such as the `RDRAND` and `RDTSC` CPU instructions, are more expensive in the Antithesis environment than they are on a conventional computer. Code which busy-waits while reading the system clock may cause performance problems.

### Memory

Your machine runs with 10 GB of memory; it divides this memory among your containers and reserves a small amount for the system itself. This limit can be increased upon request, but we strongly recommend economizing if possible. Memory-intensive tests are also slow tests, and slow tests find fewer bugs. There are techniques in our [optimization guide](/docs/best_practices/optimizing) which can help you simulate real-world production behavior in a memory-constrained environment.

## The container environment

This section describes the modifications we make to your containers at runtime.

### Networking

Your containers will run without any connectivity to any other computer outside the simulation (such as the internet). They will also be isolated to a network namespace that prevents them from reaching the host environment. The containers can communicate with each other, and we will automatically inject entries into each of their `/etc/hosts` files that enable them to look each other up. These hostnames correspond to the container names defined in the [docker-compose.yaml](/docs/setup/docker_compose/#set-up-container-orchestration) file which you built into your configuration image. If you did not provide container names, they will default to the service names instead.

> **Warning**
>
> If you wish to turn off this automatic hostname injection -- for instance, because you want to test real DNS resolution in the presence of intermittent network faults -- please let us know.

### Capturing output

By default, everything written to the `STDOUT` and `STDERR` file descriptors of the first process executed in your container is captured by Antithesis. Antithesis assumes it to be unstructured text and presents it as program output logs in the [triage](/docs/product/understanding_test_results/reports/) and [bug](/docs/product/understanding_test_results/reports/) reports. This is sufficient for many applications. However if your application prefers to log to a file, or if the main process of your container spawns a number of children whose output you do not want interleaved, Antithesis offers an alternative, more powerful approach to capturing output.

> **Note**
>
> For each simulation hour within the Antithesis environment, Antithesis will provide two hundred (200) megabytes of searchable log storage and container image storage for a customer for six (6) months.

When run in Antithesis, your container will have the variable `ANTITHESIS_OUTPUT_DIR` injected into its environment. This variable points to a directory with special properties. File creation and subdirectory creation behaves as normal, but for all writes to files it is an *output sink*: everything written will vanish immediately and cannot be read back. The data that has been written will be captured by Antithesis and will appear in your reports. Moreover, the data will be disambiguated with the name of the container that wrote the data *and* the full filesystem path within the output directory.

For example, if the following code is executed in a container named `app`:

```bash
mkdir -p $ANTITHESIS_OUTPUT_DIR/foo/bar
echo "hello" > $ANTITHESIS_OUTPUT_DIR/foo/bar/world
```

Then the following log line will be included in your Antithesis report:

On the other hand, you open and write to a file with the `.bin` extension, Antithesis will interpret it as raw binary and display a base64 encoded representation in your logs.

Suppose that you write the string `"Something in binary"` to `$ANTITHESIS_OUTPUT_DIR/foo/bar.bin`. Then the following log line will be included in your Antithesis report:

Note that the output of "U29tZXRoaW5nIGluIGJpbmFyeQo=" decodes back to the original string "Something in binary" in a Base64 decoding tool. Try it!

It's safe to set the `ANTITHESIS_OUTPUT_DIR` variable to a directory of your choice when running your tests outside Antithesis. This simplifies the architecture of your test harness, as it allows you to configure your tests both inside and outside Antithesis with a single variable.

#### Generating structured events

By default, Antithesis assumes that all writes to the output directory are unstructured text or binary. However, if you open and write to a file with the `.jsonl` extension, then Antithesis will instead interpret the output as [line-delimited JSON](https://jsonlines.org/), and automatically parse it into a structured [event](/docs/product/debugging/advanced_multiverse_debugging/event_sets/) representation.

Suppose you write `{"hello": "world"}` to `$ANTITHESIS_OUTPUT_DIR/foo/bar.jsonl`

Then the corresponding `Event` will have a `.hello` property with a value of `world`:

### Random devices

When your containers are run with the Antithesis environment, the usual random devices `/dev/random` and `/dev/urandom` are replaced with special devices whose random entropy is entirely provided by the Antithesis platform. This can be a handy fallback for integrating randomized [test template](/docs/product/writing_tests/test_templates/) or application code with Antithesis -- if it's impossible to use the [SDK](/docs/reference/sdk/). Unlike some Linux environments, there is no difference between `/dev/random` and `/dev/urandom` when running in Antithesis -- they have identical performance and identical quality entropy.

> **Warning**
>
> Many languages, frameworks, and runtimes have built-in PRNG abstractions that are initialized at runtime. Within Antithesis, this is an anti-pattern, because it means that we cannot go back just a little bit and "change history", but need to restart your program from scratch in order to get a different random sequence. Instead, you should be getting random values directly from the [Antithesis SDK](/docs/reference/sdk/), or from the system random devices `/dev/random` or `/dev/urandom`. If that's impractical, then at the very least you should be periodically reseeding the PRNG that you are using from these sources.

### Library path

If your code is [instrumented](/docs/product/writing_tests/instrumentation/coverage_instrumentation/), it will gain a dynamic dependency against our stub runtime library, `libvoidstar.so`. It's a good practice to package this library in your container, so that you're able to test your setup [outside Antithesis](/docs/setup/docker_compose/#test-your-setup-locally). But within Antithesis, we need to replace this stub version of our library with the real version that will integrate with our platform.

When a container is run within the Antithesis environment, the real implementation of our runtime library is injected at `/usr/lib/libvoidstar.so`. Antithesis does not manipulate the `LD_LIBRARY_PATH` or `LD_PRELOAD` variables inside your containers, because this could interfere with the proper functioning of your software. Instead, we write the above path into [/etc/ld.so.preload](https://man7.org/linux/man-pages/man8/ld.so.8.html). which ensures that the real implementation is loaded before the stub implementation. This approach allows our runtime library to coexist with the LLVM sanitizer runtime, and also means you do not need to modify the library search path.

### AWS services and other third-party infrastructure

Need to be emulated with a stub or mock. We have preferred, pre-built mocks of many AWS services. Please refer to [Emulating External Dependencies](/docs/reference/dependencies/).

## Detecting whether you are running within Antithesis

Many customers want to be able to detect whether their code is running within Antithesis. For example, once within Antithesis, customers might switch to local mocks for third-party web services, or set particular parameters to [values that benefit from testing](/docs/best_practices/optimizing#configure-for-testing). We recommend using the presence of the `ANTITHESIS_OUTPUT_DIR` environment variable to do this. It is guaranteed to be present when your tests are running within Antithesis, and it's easy for you to set if you want to [test your Antithesis setup locally](/docs/setup/docker_compose/#test-your-setup-locally).
