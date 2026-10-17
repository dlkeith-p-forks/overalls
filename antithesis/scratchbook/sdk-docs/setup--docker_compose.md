# Docker Compose setup guide
This is a step-by-step guide to setting up your software to run in Antithesis.

> **Tip**

This guide will walk you through orchestrating your software with Docker Compose and pushing it to the Antithesis registry.

If you're running your software with Kubernetes, follow the [Kubernetes setup guide](/docs/setup/kubernetes/) instead.

## Requirements

1. Make sure you have a container registry and credentials -- or [contact us](/docs/faq/poc_faq/) to request them.

2. Make sure your software is packaged as Linux container images ready to run without internet access. See [Containerizing your software](/docs/setup/overview/) for details.

**Need help?**

If you run into trouble, or simply want to make sure your testing is as thorough as possible, our solutions engineering team would be happy to help -- email us at support@antithesis.com or [join our Discord](https://discord.com/invite/antithesis).

## Set up container orchestration

We expect you to deliver a container image that contains a specific directory structure of what to run. We call this the `config` image.

In this image, include:

- Any configuration files expected by the containers: license files, settings, environment variables file, or other resources.
- A container orchestration file, `docker-compose.yaml`.

The `docker-compose.yaml` file in this directory lists each of the services you want to have running, the container image that the service should be started from, any external volumes that should be mounted into that container, and other options.

Here's an example `docker-compose.yaml` which uses a `.env` file to declare environment variables. Docker Compose offers [multiple ways to set environment variables](https://docs.docker.com/compose/how-tos/environment-variables/set-environment-variables/) within your containers.

```bash
# env variables
POSTGRES_ROOT_PASSWORD=your_root_password
POSTGRES_DATABASE_NAME=your_database_name
POSTGRES_USERNAME=your_user_name
POSTGRES_PASSWORD=your_user_password
```

```yaml
version: '3.0'

services:
  application1:
    container_name: application1
    hostname: application1
    image: mycompany/my_app_1:my_tag

  application2:
    container_name: application2
    hostname: application2
    image: mycompany/my_app_2:my_tag

  database:
    container_name: database
    hostname: database
    image: docker.io/library/postgres:17.2
    environment:
      POSTGRES_ROOT_PASSWORD: ${POSTGRES_ROOT_PASSWORD}
      POSTGRES_DATABASE: ${POSTGRES_DATABASE_NAME}
      POSTGRES_USER: ${POSTGRES_USERNAME}
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD}
    volumes:
      - ./volumes/database:/usr/bin/database/data
```

> **Note**

> **Warning**

This is often the trickiest part of the process for users who don't already deploy software in containers. If you simply follow the example above, you should be on solid ground, but if you run into trouble, here are a few resources you might find helpful:

- [Official Docker Compose documentation](https://docs.docker.com/compose/)
- [Our Docker best practices guide](/docs/best_practices/docker_best_practices/)
- Or you can email us at support@antithesis.com

To build your `config` image, copy all configuration files and add them to a [scratch image](https://docs.docker.com/develop/develop-images/baseimages/#create-a-simple-parent-image-using-scratch):

```docker
FROM scratch
COPY docker-compose.yaml /docker-compose.yaml
```

Here are the contents of our example `config` directory:

```shell
$ ls -a config/
.
..
docker-compose.yaml
license
```

## Add a ready signal for fuzzing

Before running any tests, Antithesis initializes your software and its dependencies. Once your system is up and running, it should emit a `setup_complete` message to initiate testing.

> **Important**

> **Warning**

[Our SDKs](/docs/reference/sdk/) provide pre-built ways to emit this message. If you cannot use our SDKs, write the following [JSONL](https://jsonlines.org/) message to `$ANTITHESIS_OUTPUT_DIR/sdk.jsonl` -- in our environment, we'll ensure that this variable and the directory it points to always exist.

```json
{"antithesis_setup": { "status": "complete", "details": {"message": "Set up complete - ready for testing!" }}}
```

> **Note**

## Test your setup locally

To test your container orchestration locally, from inside your config directory, run:

```shell
$ docker-compose up
```

This should produce a running system.

However, we want to test that this all still works **without any access to the internet**. If you're on a Linux machine, first enter a network namespace before running the command:

```shell
$ pwd
/home/user/config

$ unshare -n

[2] $ docker-compose up
...
[Lots of output]
...
```

If everything still comes up and works, and your services all find each other, then the hardest part is done. Now you're ready to deploy to the Antithesis environment for testing!

## Push your images

When you become a customer, we configure a container registry for you and send you a credential file `$TENANT_NAME.key.json`.

To authenticate to your container registry, run the following command:

```shell
$ cat $TENANT_NAME.key.json | docker login -u _json_key https://us-central1-docker.pkg.dev --password-stdin
```

Now you're locally authenticated to the registry and can run all other Docker commands as normal.

Push your **custom** and **non-public** images (including your config image) to: `us-central1-docker.pkg.dev/molten-verve-216720/$TENANT_NAME-repository/`.

For example, if your local image is named `my_app`, you'd tag it as it's referenced in your `docker-compose.yaml` and push it as follows:

```shell
$ docker tag my_app:my_tag us-central1-docker.pkg.dev/molten-verve-216720/$TENANT_NAME-repository/my_app
$ docker push us-central1-docker.pkg.dev/molten-verve-216720/$TENANT_NAME-repository/my_app:my_tag
```

Images that are publicly available (e.g. `docker.io/library/postgres:17.2`) can be referenced directly in your config files -- you do not need to copy them into the Antithesis registry.

## Run in Antithesis

Your software is now ready to run in Antithesis!

To check your setup is working correctly, launch a first test run in the web app in [setup mode](/docs/setup/setup_mode/). Go to the **Test launchers** page at `https://$TENANT_NAME.antithesis.com/test-launchers`, and select **Basic Test** with the **Setup mode** option checked. Enter a duration of 15 minutes and click **Launch the setup run**.

Setup mode streams your build and setup logs, and lets you iterate on your config files until you're ready to launch a full test.

Once you're happy with your setup, you can either:

- Launch a full test run straight away and learn how to view test results
- Write your first test to exercise your system and start finding bugs, then launch a test run

### Launch a test run

To launch a full run, go back to the **Test launchers** page and launch another **Basic Test** with **Setup mode** unchecked. Select **Launch the test run**.

You can also launch tests through [Snouty CLI](https://antithesis.com/docs/ai/snouty/#launch-a-test-run) or through your CI. See [Launching tests](/docs/product/launching_tests) for more details.

You can view results stream in to the [Logs Explorer](/docs/product/understanding_test_results/logs_explorer/). When your run is finished, you can view the full results in the [triage report](/docs/product/understanding_test_results/reports/).

### Write your first test

To test your system and find bugs, Antithesis needs to exercise your software. We do this using a test template -- code that makes your software do something.

As a first test of your setup, you can take one of your existing integration tests and run it as a [singleton test](/docs/product/writing_tests/test_templates/test_composer_reference/#singleton-driver-command) (a test that runs once in a given test timeline). To do this, use the following naming conventions to enable Antithesis to detect and run your test. These conventions should be followed exactly.

1. Create a directory called `/opt/antithesis/test/v1/quickstart` in any of your containers.

2. Paste an existing integration test into an executable named `singleton_driver_<your_test_name>.<extension>` in the directory you just created. Make sure your executable has an appropriate shebang in the first line, e.g. `#!/usr/bin/env bash`

Now you'll need to validate that your system can find the test template you just defined -- [details here](/docs/product/writing_tests/test_templates/testing_locally/). The easiest way to do this is to call `docker compose exec` on your test command and see if it runs.

```shell
$ docker compose exec <your_service_name> /opt/antithesis/test/v1/quickstart/singleton_driver_<your_test_name>
```

Once you've written a test, run [setup mode](/docs/setup/setup_mode/) again and then [launch a full test run](/docs/setup/docker_compose/#launch-a-test-run).

See [Writing tests](/docs/product/writing_tests) for more advanced testing practices, like using parallel tests or adding assertions.
