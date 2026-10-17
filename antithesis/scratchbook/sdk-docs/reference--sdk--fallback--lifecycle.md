# Lifecycle functionality (Fallback SDK)
Our SDKs allow indicating when certain milestones in program setup and execution have been reached. If you cannot use the SDK, you can still indicate these milestones by writing [JSONL](https://jsonlines.org/) messages to `$ANTITHESIS_OUTPUT_DIR/sdk.jsonl`.

> **Important**
>
> You must emit JSONL messages. Each individual message must be a single line of JSON that terminates in a newline character. However, the examples show JSON messages spread across multiple lines purely for readability. This will not work in practice. Each message must be a single line.

## Setup

*Setup* indicates to Antithesis that your system and workload are fully initialized.

To use this functionality, have your program emit the following JSONL once startup is complete:

```json
{"antithesis_setup": { "status": "complete" }}
```

The optional item `details` is a JSON object of additional information that you wish to log at startup time. If you do not want to record additional information, omit the key as above. Note that `details` must not terminate with a newline, because the entire message must ultimately be JSONL.

An empty object `{}` is also valid and need not be omitted. Values within a details object may be any JSON value, including `null`.

The following *setup* example logs additional information by setting `details`:

```json
{"antithesis_setup": { "status": "complete", "details": {"workload-size": 37, "initiated_by": "John Doe" }}}
```

## Event

*Event* indicates to Antithesis that a certain event has been reached. It provides greater information about the ordering of events during the course of testing in Antithesis. It is a JSONL message consisting of:

- a single top-level field that is the event's name, which points to
- a JSON object containing any details you want to log. If you have no details to log, use an empty object `{}`. Note that these details must not contain any newlines except for the newline that terminates the message. The entire message must ultimately be JSONL.

To use this functionality, have your program emit a JSONL message when the event is reached. Your message should look similar to the following (but **without** newlines, which are only for readability):

```json
{
    "your_event_name": {
        "node_status": "up",
        "nodes_up": ["worker 1", "worker 2", "worker 3"]
    }
}
```
