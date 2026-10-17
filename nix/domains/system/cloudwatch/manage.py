"""Idempotent AWS resource reconciliation, never a log receiver."""

import configparser
import json
import os
import sys
from pathlib import Path
from typing import TYPE_CHECKING, TypedDict

import boto3

if TYPE_CHECKING:
    import botocore.client


class Settings(TypedDict):
    environment: str
    region: str
    accountId: str
    partition: str
    groups: dict[str, str]
    retentionDays: dict[str, int]
    kmsKeyArn: str | None
    queueAlarmBytes: int
    expectedHosts: list[str]
    alarmActions: list[str]
    credentialsFile: str | None
    roleArn: str | None


def string(value: object) -> str:
    if not isinstance(value, str):
        raise ValueError("expected string")
    return value


def integer(value: object) -> int:
    if type(value) is not int:
        raise ValueError("expected integer")
    return value


def object_value(value: object) -> dict[str, object]:
    if not isinstance(value, dict):
        raise ValueError("expected object")
    return value


def settings_value(raw: object) -> Settings:
    row = object_value(raw)
    groups_row = object_value(row["groups"])
    retention_row = object_value(row["retentionDays"])
    return Settings(
        environment=string(row["environment"]),
        region=string(row["region"]),
        accountId=string(row["accountId"]),
        partition=string(row["partition"]),
        groups={name: string(value) for name, value in groups_row.items()},
        retentionDays={name: integer(value) for name, value in retention_row.items()},
        kmsKeyArn=string(row["kmsKeyArn"]) if row["kmsKeyArn"] is not None else None,
        queueAlarmBytes=integer(row["queueAlarmBytes"]),
        expectedHosts=[string(value) for value in object_list(row["expectedHosts"])],
        alarmActions=[string(value) for value in object_list(row["alarmActions"])],
        credentialsFile=(
            string(row["credentialsFile"]) if row["credentialsFile"] is not None else None
        ),
        roleArn=string(row["roleArn"]) if row["roleArn"] is not None else None,
    )


def object_list(value: object) -> list[object]:
    if not isinstance(value, list):
        raise ValueError("expected array")
    return value


def reconcile(
    logs: "botocore.client.BaseClient",
    metrics: "botocore.client.BaseClient",
    settings: Settings,
) -> None:
    tags = {"project": "overalls", "environment": settings["environment"], "managed-by": "overalls"}
    for source, group in settings["groups"].items():
        try:
            options = {"logGroupName": group}
            if settings["kmsKeyArn"]:
                options["kmsKeyId"] = settings["kmsKeyArn"]
            logs.create_log_group(**options)
        except logs.exceptions.ResourceAlreadyExistsException:
            pass
        logs.put_retention_policy(
            logGroupName=group, retentionInDays=settings["retentionDays"].get(source, 90)
        )
        arn = f"arn:{settings['partition']}:logs:{settings['region']}:{settings['accountId']}:log-group:{group}"
        logs.tag_resource(
            resourceArn=arn,
            tags=tags
            | {
                "source": source,
                "sensitivity": "restricted"
                if source in ["audit", "firecracker"]
                else "operational",
            },
        )
        if settings["kmsKeyArn"]:
            logs.associate_kms_key(logGroupName=group, kmsKeyId=settings["kmsKeyArn"])
    if settings["expectedHosts"]:
        group = settings["groups"]["operations"]
        namespace = "Overalls/" + settings["environment"]
        for identity in settings["expectedHosts"]:
            name = "HostHeartbeat_" + identity
            logs.put_metric_filter(
                logGroupName=group,
                filterName=name,
                filterPattern='{ ($.payload.event = "logging.heartbeat") && ($.origin.machine_id = "'
                + identity
                + '") }',
                metricTransformations=[
                    {
                        "metricName": name,
                        "metricNamespace": namespace,
                        "metricValue": "1",
                        "defaultValue": 0,
                    }
                ],
            )
            metrics.put_metric_alarm(
                AlarmName=settings["environment"] + "-" + name,
                Namespace=namespace,
                MetricName=name,
                Statistic="Sum",
                Period=60,
                EvaluationPeriods=5,
                DatapointsToAlarm=5,
                Threshold=1,
                ComparisonOperator="LessThanThreshold",
                TreatMissingData="breaching",
                AlarmActions=settings["alarmActions"],
            )

            if "metrics" in settings["groups"]:
                for suffix, field, threshold in [
                    ("QueueBytes", "queue_bytes", settings["queueAlarmBytes"]),
                    ("OldestChunk", "oldest_chunk_seconds", 3600),
                    ("DroppedRecords", "export_dropped", 0),
                    ("ExportErrors", "export_errors", 0),
                    ("FirecrackerDroppedLogs", "firecracker_dropped_logs", 0),
                    ("FirecrackerEvictions", "firecracker_evicted_files", 0),
                ]:
                    metric_name = suffix + "_" + identity
                    logs.put_metric_filter(
                        logGroupName=settings["groups"]["metrics"],
                        filterName=metric_name,
                        filterPattern='{ ($.origin.machine_id = "'
                        + identity
                        + '") && ($.metrics.'
                        + field
                        + " = *) }",
                        metricTransformations=[
                            {
                                "metricName": metric_name,
                                "metricNamespace": namespace,
                                "metricValue": "$.metrics." + field,
                            }
                        ],
                    )
                    metrics.put_metric_alarm(
                        AlarmName=settings["environment"] + "-" + metric_name,
                        Namespace=namespace,
                        MetricName=metric_name,
                        Statistic="Maximum",
                        Period=60,
                        EvaluationPeriods=3,
                        DatapointsToAlarm=2,
                        Threshold=threshold,
                        ComparisonOperator="GreaterThanThreshold",
                        TreatMissingData="missing",
                        AlarmActions=settings["alarmActions"],
                    )


def main() -> None:
    # Import only the shared private-file reader, not the exporter entrypoint.
    # "runtime" is nix/domains/system/logging/runtime.py, supplied by the unit's
    # environment.PYTHONPATH=../logging at service start.
    from runtime import private_read  # ty: ignore[unresolved-import]

    settings = settings_value(json.loads(Path(sys.argv[1]).read_text()))
    for key in list(os.environ):
        if key.startswith("AWS_"):
            del os.environ[key]
    os.environ["AWS_CONFIG_FILE"] = "/dev/null"
    os.environ["AWS_SHARED_CREDENTIALS_FILE"] = "/dev/null"
    os.environ["AWS_EC2_METADATA_DISABLED"] = (
        "false" if settings["credentialsFile"] is None else "true"
    )
    os.environ["AWS_EC2_METADATA_V1_DISABLED"] = "true"
    kwargs = {"region_name": settings["region"]}
    if settings["credentialsFile"]:
        parser = configparser.ConfigParser(interpolation=None)
        parser.read_string(private_read(settings["credentialsFile"]))
        if parser.sections() != ["default"] or parser.defaults():
            raise ValueError("invalid profile")
        profile = dict(parser["default"])
        if (
            not {"aws_access_key_id", "aws_secret_access_key"}
            <= profile.keys()
            <= {"aws_access_key_id", "aws_secret_access_key", "aws_session_token"}
        ):
            raise ValueError("invalid credentials")
        if any(not value or "\n" in value for value in profile.values()):
            raise ValueError("invalid credentials")
        kwargs.update(profile)
    session = boto3.Session(**kwargs)
    if settings["roleArn"]:
        credentials = session.client("sts").assume_role(
            RoleArn=settings["roleArn"], RoleSessionName="overalls-log-management"
        )["Credentials"]
        session = boto3.Session(
            region_name=settings["region"],
            aws_access_key_id=credentials["AccessKeyId"],
            aws_secret_access_key=credentials["SecretAccessKey"],
            aws_session_token=credentials["SessionToken"],
        )
    reconcile(session.client("logs"), session.client("cloudwatch"), settings)
    print('{"event":"logging.management_reconciled"}')


if __name__ == "__main__":
    try:
        main()
    except Exception:
        print('{"event":"logging.management_failed"}', file=sys.stderr)
        sys.exit(1)
