# Product FAQs
**Can I use an AI agent to help me with setup?**

Yes!

If you're working with a coding agent and using Docker Compose, we offer [a set of skills](https://github.com/antithesishq/antithesis-skills) that enable your agent to do most of your Antithesis setup for you.

**Troubleshooting common setup pitfalls**

| Symptom | Cause | Fix |
| --- | --- | --- |
| Test run fails with a build error. | Incorrect container image architecture. | Build container images for x86-64 CPUs: `docker build --platform linux/amd64`. |
| Generic network connection errors. | Antithesis runs your software in a hermetic testing environment with no internet access. | Bake all dependencies into Docker images at build time or [mock them](/docs/reference/dependencies/). |
| Fault injection starts at unexpected points, e.g. during system initialization. | Antithesis expects exactly one `setup_complete` signal from the system. | Check if your system is emitting `setup_complete` from multiple containers or multiple scripts. |
| Test artifacts don't include logs you expect. | Antithesis relies on the default logging driver to capture logs from all containers. A custom logging driver in `docker-compose.yaml` will cause your logs to be filtered out. | Remove any logging driver configs and use the default. |

**How should I think about testing with Antithesis?**

To use Antithesis effectively, you need to stop thinking about testing in **imperative** terms and think in **declarative** terms. Instead of asking "what sequence of events will cause a failure?", ask "what must always be true, no matter what happens?".

|  | Traditional testing | Antithesis testing |
| --- | --- | --- |
| Test structure | Imperative: step A, then B, then assert C. | Declarative: define properties that must always/sometimes hold. |
| Fault injection | You script specific failures. | Antithesis injects faults autonomously and you don't control when or what. |
| How tests run | Tests are run outside the system where they observe and make assertions. | Tests are clients and run alongside the system, **in the same environment**. |
| Reproducibility | Flaky tests are common. | Every failure is reproducible via deterministic replay. |

Imagine you're testing a message queue. When writing an integration or end-to-end test you would:

```
Start cluster
Write message A
Kill leader broker
Read messages
Assert message A is present
```

But when testing with Antithesis, you would define:

```
Property: "Every acknowledged write is eventually readable"
Workload: Continuously write messages, continuously read messages
Assert: acknowledged messages are consumed, no data loss occurs
```

You don't script any failure scenarios. Antithesis subjects your system to a wide variety of failure scenarios for you: it kills brokers, partitions the network, and pauses processes on its own.

Your job is to:

- define correct system behavior
- give Antithesis access to as much of the code surface as you can

**How do I iterate locally and for Antithesis in the same docker-compose.yaml file?**

Antithesis expects to receive pre-built images for your containers defined in the `docker-compose.yaml` file. But, this doesn't mean you have to use two different `docker-compose.yaml` files, one for local iteration and one for Antithesis.

You can use [compose build](https://docs.docker.com/reference/compose-file/build/) to build images for local iteration, and define pre-built images for Antithesis to pull.

Here's an example:

```yaml
 my-container:
    image: ${REPOSITORY}/my-container-image:${IMAGES_TAG:-latest}
    build:
      context: ../somedir
      tags:
        - ${REPOSITORY}/my-container-image:latest
    hostname: my-container
    container_name: my-container
    init: true
    depends_on:
      - "other-service-1"
      - "other-service-2"
```

`${REPOSITORY}` is an environment variable injected via a .env file. You must set this variable for the above to work.

When iterating locally, to bring up your system, run:

```
docker-compose up --build
```

This rebuilds containers which have a `build` attribute and tags them as `latest`.

When Antithesis attempts to bring up your system, it'll use the pre-built images by resolving the `REPOSITORY` and `IMAGES_TAG` env variables you define in a .env file. If you don't set `IMAGES_TAG`, it defaults to `latest`.

**How do I validate my setup?**

You can manually validate your setup by disconnecting from the internet, running `docker-compose up` locally and verifying that all services are running as expected. If this happens, you should be able to call the [`basic_test`](/docs/reference/webhook/test_webhook/) webhook successfully.

To streamline this process, you can automate it using a GitHub Action. The [example workflow](https://github.com/antithesishq/etcd-test-composer/blob/gh-action-docker-compose-up/.github/workflows/build-push-validate-test.yml) includes steps to build the project, validate the local setup, run and validate test commands, and finally call the [`basic_test`](/docs/reference/webhook/test_webhook/) endpoint.

We recommend setting up either this or a similar workflow in your CI pipeline.

**How do I validate test commands locally?**

To validate your test commands locally:

- Run `docker-compose up`, without internet connection, to bring up your system.
- Run the individual test commands using `docker exec <CONTAINER_NAME> path/to/test-file/`. `<CONTAINER_NAME>` is the container containing the test command.

If the test commands run successfully then you're good to kick off an actual test. [This page](/docs/product/writing_tests/test_templates/testing_locally/) has more details.

**How often should we test?**

Most Antithesis customers run tests nightly to catch bugs and regressions as early in development as possible, and some also run shorter tests on every commit to help reduce the feedback cycle for active development.

- Nightly tests:
  - Run for 6-8hrs.
  - Uncover bugs that are hard to find. The longer a test runs, the more states are explored.

- Short tests:
  - Run on a commit to the main development branch.
  - Run for ~30min - 1hr.
  - Catch simple bugs that slipped through conventional unit and end-to-end tests.

**What are “test hours” and how are they measured?**

“Test hours” refers to the total time the System Under Test (SUT) experiences across an entire test run.

It's roughly equivalent to the total active CPU time during the run, and can be estimated as:
`antithesis.duration × number of CPU cores provisioned`.

**Why does my test last longer than the duration I configured?**

The duration you choose when you launch your test is the amount of wall-clock time Antithesis spends actively testing your system. The full duration of the test will be longer because it also includes set up and build time.

**Is there a way to bias test runs? If I believe there's a bug in subsystem X can I get Antithesis to apply more effort to a subset of our tests?**

Yes, there are several ways to focus on a particular subsystem:

- Write more [test drivers](/docs/product/writing_tests/test_templates/test_composer_reference/#types-of-test-commands) that call the subsystem.
- Put more [assertions](/docs/product/writing_tests/assertions/) in the subsystem or the clients that exercise the subsystem.
- Talk to our customer success engineers to help tune the configuration: support@antithesis.com.

**Which S3 mocks do you support?**

We support [MinIO](https://min.io/) and [LocalStack](https://www.localstack.cloud/) services. [This page](/docs/reference/dependencies/) has more details, and a long list of mocks for other dependencies.

**Is there a logging limit in Antithesis? Can I run my system with full debugging logs?**

Best practice when testing with Antithesis is to use a moderate amount of logging -- remember that the platform's determinism makes it easy to reproduce and replay any bug you find, and with [multiverse debugging](/docs/product/debugging/advanced_multiverse_debugging/overview/) you can turn full debugging logs on at any point during the replay.

For each simulation hour within the Antithesis environment, Antithesis will provide two hundred (200) megabytes of searchable log storage and container image storage for a customer for six (6) months.

If your system exceeds the 200 MB/test hour limit, the output/logging limit property in your report will fail. [This section](/docs/best_practices/optimizing/#avoid-excessive-logging-output) has details on how to do this.

Can you run with full DEBUG logs? Well, it depends on:

- How verbose your DEBUG logs are.
- How many services are logging at DEBUG level.
- Where the logs are written (e.g., DEBUG to disk, INFO to stdout is preferable).
- The overall scale of your system.

In general, smaller-scale systems with flexible logging setups are more likely to stay within the limit.

**What are some common uses of sometimes assertions?**

[Sometimes assertions](/docs/best_practices/sometimes_assertions/) are important signposts along timelines that can be useful in many ways.

1. Making rare bugs more common: If you encounter a bug infrequently and you want to reproduce it with more logging, you should add a sometimes assertion in the relevant parts of code. Or if you've tackled a flaky issue and want to make sure it's actually fixed, sometimes assertions help Antithesis hit those code blocks more often.

2. Hit more edge cases in a test: It's useful to write sometimes assertions for known edge cases that you want to test, so you know that the test actually ran your edge case. If it doesn't pass, maybe you're either not running the simulation long enough or you need to strengthen your test template to hit this scenario. For example, if you're writing a search algorithm, maybe you add a sometimes assertion to ensure that Antithesis has encountered scenarios where the item is at the end of the list.

3. Ensure the system is being exercised: Make sure that minimum amount of work is being done during each test. Adding simple and intuitive sometimes assertions of some work being done in the system provides assurance that your system was correctly exercised. For example, if your product is a database, maybe you add a sometimes assertion to ensure Antithesis has encountered scenarios where a table has more than 1000 rows.

**What exactly are the features of the simulated CPU that you use to run software?**

We're so glad you asked! You can find them [here](/docs/configuration/cpuid/).

**Why isn't MY question covered here?**

Probably because we don't know about it! Please drop us a line at support@antithesis.com or ask us on [Discord](https://discord.gg/antithesis).
