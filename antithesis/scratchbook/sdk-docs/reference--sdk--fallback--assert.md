# Assertion functionality (Fallback SDK)
Our SDKs permit you to conveniently define [test properties](/docs/introduction/how_antithesis_works/#how-does-antithesis-identify-bugs) through writing assertions inline in your code. [If you cannot use the SDK](/docs/reference/sdk/fallback/), you can still use our assertions framework by writing JSONL messages to `$ANTITHESIS_OUTPUT_DIR/sdk.jsonl`. These assertions will be recognized by our platform, which will evaluate the assertions and record the results in our reports.

> **Important**
>
> You must emit JSONL messages. Each individual message must be a single line of JSON that terminates in a newline character. However, the examples show JSON messages spread across multiple lines purely for readability. This will not work in practice. Each message must be a single line.

You must write two messages in [JSONL](https://jsonlines.org/) format per assertion: one for **assertion declaration** in the *catalog* at startup, and another for **assertion evaluation** when encountered during execution. An example of two such JSONL messages follows: the first declares a *Sometimes Assertion* at startup and the second later notes that the assertion has been encountered. Since you will be using your language of choice, the example is written in pseudocode and will differ from your implementation.

### Assertion declaration: at program startup

```rust
fn startup (){
    # The SDK directory is $ANTITHESIS_OUTPUT_DIR/sdk.jsonl
    # but this only has meaning in bash
    output_path = getenv($ANTITHESIS_OUTPUT_DIR) + '/sdk.jsonl'
    sdk_capture_file = open(output_dir)

    # Create the declaration message
    # Most fields need to have the same value as in the evaluation below
    declaration =
    {
        "antithesis_assert": {
            "hit": false,
            "must_hit": true,
            "assert_type": "sometimes",
            "display_type": "Sometimes",
            "message": "Server sometimes is leader",
            "condition": false,
            "id": "Server sometimes is leader",
            "location": {
                "class": "main",
                "function": "main",
                "file": "/src/glitch-grid/go/control.go",
                "begin_line": 239,
                "begin_column": 0
            }
        }
    }

    # Antithesis needs JSON to be on a single-line
    leader_assertion_declare = toJSON(declaration, newlines=FALSE)

    # Write the JSONL to the output dir
    sdk_capture_file.write(leader_assertion_declare)
    # The assertion has now been declared

    [More catalog declarations]
    # Keep writing other JSONL to the catalog here
    [Other startup code]
    ...
}
```

### Assertion evaluation:  during runtime

```rust
fn main(){
    startup()
    ...
    [Project code]
    # We would like to invoke the assertion at this point in the code.
    # We will test if the server is the leader.
    # We do not know if the test condition is true yet and we do not know the details yet.
    # Create the evaluation message
    evaluation =
    {
        "antithesis_assert": {
            "hit": true,
            "must_hit": true,
            "assert_type": "sometimes",
            "display_type": "Sometimes",
            "message": "Server sometimes is leader",
            "condition": null,
            "id": "Server sometimes is leader",
            "location": {
                "class": "main",
                "function": "main",
                "file": "/src/glitch-grid/go/control.go",
                "begin_line": 239,
                "begin_column": 0
            }
        }
    }

    # Imagine we have a method that returns true if the server is the leader
    evaluation.antithesis_assert.condition = server.isLeader()

    # You should only record the first true evaluation and
    # the first false evaluation of an assertion (see below)
    [code to check if assertion evaluation is redundant]
    # Suppose the assertion is not redundant so the message should be written

    # Get further details for logging with imaginary methods; details is an
    # optional JSON object — include the key only when you have some
    evaluation.antithesis_assert.details = {
        priority_number: server.getPriorityNumber(),
        leader_start_time: server.getLeaderStartTime()
    }


    # We have already opened the SDK capture file earlier
    # Antithesis needs JSON to be on a single line
    leader_assertion_evaluate = toJSON(evaluation, newlines=FALSE)
    sdk_capture_file.write(leader_assertion_evaluate)
    # The assertion will be evaluated when this is written.
    [Further project code]
    ...
}
```

The evaluation message might look like the following after `details` and `condition` are added:

```json
{
    "antithesis_assert": {
        "hit": true,
        "must_hit": true,
        "assert_type": "sometimes",
        "display_type": "Sometimes",
        "message": "Server sometimes is leader",
        "condition": true,
        "id": "Server sometimes is leader",
        "location": {
            "class": "main",
            "function": "main",
            "file": "/src/glitch-grid/go/control.go",
            "begin_line": 239,
            "begin_column": 0
        },
        "details": {"priority_number": 0, "leader_start_time": "2024-03-09 10:30:05.008" }
    }
}
```

## Syntax

A given assertion has the top-level key `antithesis_assert`, which has the fields found below.

###### `hit`

*Boolean*. Indicates whether the assertion has been encountered yet or not. The declaration value is always different from the evaluation value: For declarations it is always `false` and for evaluations it is always `true`.

###### `must_hit`

*Boolean*. Indicates whether not hitting the assertion represents failure. It varies between different assertion functions: the combination of `must_hit` and `assert_type` determine what specific assertion function you are calling. The declaration value is always the same as the evaluation value.

###### `assert_type`

*String*, one of `"always"`, `"sometimes"`, or `"reachability"`. It varies between different assertion functions: the combination of `must_hit` and `assert_type` determine what specific assertion function you are calling. The declaration value is always the same as the evaluation value.

###### `display_type`

*String*. Customizes the name of assertion types displayed in the *details* section of Antithesis reports. Users should generally use the Antithesis defaults, which this documentation consistently uses. The declaration value is always the same as the evaluation value.

###### `message`

*String*. A human-readable message that becomes the name of the corresponding test property. The declaration value is always the same as the evaluation value.

###### `condition`

*Boolean*. The result of evaluating the desired test condition. This is not normally hardcoded, but is rather evaluated at runtime. The declaration value might be different from the evaluation value: For declarations it is always `false`, and for evaluations it might be either `true` or `false`.

Assertions of `assert_type`: `"reachability"` do not have a test condition. Arbitrarily, this field is hardcoded to `true` for *reachable* function evaluation messages and `false` for *unreachable* function evaluation messages.

###### `id`

*String*. The identifier used to aggregate assertions. Antithesis generates one test property per unique `id`. This test property either passes or fails, which depends upon the evaluation of every assertion that shares its `id`. Different assertions in different parts of the code should have different `id`'s, but the same assertion should always have the same `id` even if it is moved to a different file. Antithesis uses `message` as `id` and customers should generally do the same. The declaration value is always the same as the evaluation value.

###### `location.class`

*String*. The class of the code in which the assertion is being called. If this field is not relevant for your language, use an empty string. The declaration value is always the same as the evaluation value.

###### `location.function`

*String*. The function in which the assertion is being called. If this field is not relevant for your language, use an empty string. The declaration value is always the same as the evaluation value.

###### `location.file`

*String*. The file in which the assertion is being called. The declaration value is always the same as the evaluation value.

###### `location.begin_line`

*Integer*. The line number of the assertion call. The declaration value is always the same as the evaluation value.

###### `location.begin_column`

*Integer*. The column number of the assertion call. If this field is not relevant for your language, use 0. The declaration value is always the same as the evaluation value.

###### `details`

An optional *JSON object* containing additional user-provided information that serves as context for assertion failures. Declarations omit `details`; evaluations may include a JSON object of details you wish to log. Note that `details` must not terminate with a newline, because the entire message must ultimately be JSONL.

An empty object `{}` is valid and need not be omitted. Values within a details object may be any JSON value, including `null`.

## Assertion declaration

A single assertion is declared by writing a JSONL message to `$ANTITHESIS_OUTPUT_DIR/sdk.jsonl` at startup. The collection of all such assertion declarations is called the *assertion catalog*.

The *assertion catalog* initializes the assertions. Many types of assertions are supposed to fail if they are never reached: Antithesis must be informed that these assertions exist so it can mark them as failing if they are never encountered. The catalog should be written at program startup, to ensure that Antithesis is informed of all assertions before it (potentially) begins encountering them.

> **Important**
>
> The *assertion catalog* is necessary for assertions to function correctly. However, Antithesis will attempt to evaluate every assertion it encounters even if the assertion wasn't previously declared.

Assertions declarations use the same format as assertion evaluations (below). However, in declarations some fields must be set to specific values. The *Syntax* and *Assertion Evaluation* sections contain all the necessary information, and this section provides the same information more conveniently. The following are the initialization values for a function declaration:

- The fields `"id"`, `"message"`, and `"location"` are the same both at declaration and at evaluation. These depend upon your program and are not given here.
- The fields that must be set verbatim in declarations are different for different *Assertion* functions. These fields are given in the table below. Each row is a different *Assertion* function and the values its fields must take.

hit
must\_hit
assert\_type
display\_type
condition
details

Always
false
true
"always"
Always
false
omitted

AlwaysOrUnreachable
false
false
"always"
AlwaysOrUnreachable
false
omitted

Sometimes
false
true
"sometimes"
Sometimes
false
omitted

Unreachable
false
false
"reachability"
Unreachable
false
omitted

Reachable
false
true
"reachability"
Reachable
false
omitted

## Assertion evaluation

An assertion is evaluated by writing a JSONL message to `$ANTITHESIS_OUTPUT_DIR/sdk.jsonl` at runtime. The result of a test property only depends upon if there is at least one `true` evaluation of the assertion and if there is at least one `false` evaluation of the assertion. There is no benefit to sending more than one `true` evaluation or more than one `false` evaluation. In your code, you should ensure that your evaluation message is not redundant before writing it.

The [complete assertion schema](/docs/reference/sdk/fallback/schema/) is provided for reference or for validation.

Details of each assertion function follow.

## Always

An `Always` assertion function asserts that a given condition is true every time the assertion is encountered **and** that it is encountered at least once. The corresponding test property will be viewable in the `Antithesis SDK: Always` group of your triage report.

You should have already declared the assertion in the catalog during startup. When you reach the point where you want to evaluate the assertion, emit a JSON message similar to the example below. The optional field `details` is a JSON object; omit the key if you have no details to log. Note that `details` must not terminate with a newline, because the entire message must ultimately be JSONL.

To set `condition` you should evaluate the desired test condition in your language of choice and store the results in this field.

All the fields that must be set verbatim are highlighted. Remember that newlines are only for readability and you must emit JSONL messages.

```json mark={3-6}
{
    "antithesis_assert": {
        "hit": true,
        "must_hit": true,
        "assert_type": "always",
        "display_type": "Always",
        "message": "Control service queue is non-empty",
        "condition": true,
        "id": "Control service queue is non-empty",
        "location": {
            "class": "main",
            "function": "main",
            "file": "/src/glitch-grid/go/control.go",
            "begin_line": 195,
            "begin_column": 0
        }
    }
}
```

## AlwaysOrUnreachable

An `AlwaysOrUnreachable` assertion function asserts that some condition is true every time it is encountered. The corresponding test property will pass if the assertion is never encountered (unlike `Always` assertion types). The test property will be viewable in the `Antithesis SDK: Always` group of your triage report.

You should have already declared the assertion in the catalog during startup. When you reach the point where you want to evaluate the assertion, emit a JSON message similar to the example below. The optional field `details` is a JSON object; omit the key if you have no details to log. Note that `details` must not terminate with a newline, because the entire message must ultimately be JSONL.

To set `condition` you should evaluate the desired test condition in your language of choice and store the results in this field.

All the fields that must be set verbatim are highlighted. Remember that newlines are only for readability and you must emit JSONL messages.

```json mark={3-6}
{
    "antithesis_assert": {
        "hit": true,
        "must_hit": false,
        "assert_type": "always",
        "display_type": "AlwaysOrUnreachable",
        "message": "Control service started",
        "condition": true,
        "id": "Control service started",
        "location": {
            "class": "main",
            "function": "main",
            "file": "/src/glitch-grid/go/control.go",
            "begin_line": 299,
            "begin_column": 0
        }
    }
}
```

## Sometimes

A `Sometimes` assertion function asserts that a given state is encountered at some point across the entire testing session. The corresponding test property will pass if the assertion evaluates to `true` at least once. (If the assertion is never encountered, the test property will therefore fail.) The test property will be viewable in the `Antithesis SDK: Sometimes` group.

You should have already declared the assertion in the catalog during startup. When you reach the point where you want to evaluate the assertion, emit a JSON message similar to the example below. The optional field `details` is a JSON object; omit the key if you have no details to log. Note that `details` must not terminate with a newline, because the entire message must ultimately be JSONL.

To set `condition` you should evaluate the desired test condition in your language of choice and store the results in this field.

All the fields that must be set verbatim are highlighted. Remember that newlines are only for readability and you must emit JSONL messages.

```json mark={3-6}
{
    "antithesis_assert": {
        "hit": true,
        "must_hit": true,
        "assert_type": "sometimes",
        "display_type": "Sometimes",
        "message": "Server sometimes is leader",
        "condition": true,
        "id": "Server sometimes is leader",
        "location": {
            "class": "main",
            "function": "main",
            "file": "/src/glitch-grid/go/control.go",
            "begin_line": 239,
            "begin_column": 0
        },
        "details": {"priority_number": 0, "leader_start_time": "2024-03-09 10:30:05.008" }
    }
}
```

## Reachable

A `Reachable` assertion function asserts that a given line of code is encountered at some point across the entire testing session. The corresponding test property will pass if the assertion is encountered at least once. (If the assertion is never encountered, the test property will therefore fail.) The test property will be viewable in the `Antithesis SDK: Reachability assertions` group.

You should have already declared the assertion in the catalog during startup. When you reach the point where you want to evaluate the assertion, emit a JSON message similar to the example below. The optional field `details` is a JSON object; omit the key if you have no details to log. Note that `details` must not terminate with a newline, because the entire message must ultimately be JSONL.

All the fields that must be set verbatim are highlighted. Remember that newlines are only for readability and you must emit JSONL messages.

```json mark={3-6,8}
{
    "antithesis_assert": {
        "hit": true,
        "must_hit": true,
        "assert_type": "reachability",
        "display_type": "Reachable",
        "message": "Control can start rebooting with no saved queue",
        "condition": true,
        "id": "Control can start rebooting with no saved queue",
        "location": {
            "class": "main",
            "function": "main",
            "file": "/src/glitch-grid/go/control.go",
            "begin_line": 199,
            "begin_column": 0
        },
        "details": {"queue_size": 0, "needs_reboot": true}
    }
}
```

## Unreachable

An `Unreachable` assertion function asserts that a given line of code is never encountered across the entire testing session. The corresponding test property will fail if this assertion is ever encountered. (If the assertion is never encountered, the test property will therefore pass.) The test property will be viewable in the `Antithesis SDK: Reachability assertions` group.

You should have already declared the assertion in the catalog during startup. When you reach the point where you want to evaluate the assertion, emit a JSON message similar to the example below. The optional field `details` is a JSON object; omit the key if you have no details to log. Note that `details` must not terminate with a newline, because the entire message must ultimately be JSONL.

All the fields that must be set verbatim are highlighted. Remember that newlines are only for readability and you must emit JSONL messages.

```json mark={3-6,8}
{
    "antithesis_assert": {
        "hit": true,
        "must_hit": false,
        "assert_type": "reachability",
        "display_type": "Unreachable",
        "message": "Control handles null values",
        "condition": false,
        "id": "Control handles null values",
        "location": {
            "class": "main",
            "function": "main",
            "file": "/src/glitch-grid/go/control.go",
            "begin_line": 34,
            "begin_column": 0
        }
    }
}
```
