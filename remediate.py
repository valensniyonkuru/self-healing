# remediate.py — TechStream Self-Healing lab (Step 5)
# Lambda function (Python 3.12) triggered by EventBridge when
# TechStream-HighErrorRate alarm transitions to ALARM.
#
# Remediation order:
#   1. Discover EC2 instances tagged Project=TechStream / Lab=SelfHealing
#   2. Send SSM RunCommand "systemctl restart techstream-app" to each instance
#   3. If SSM fails for any instance, fall back to ASG SetDesiredCapacity + 1
#   4. Log every action and outcome to CloudWatch Logs (captured automatically
#      because Lambda writes to stdout/stderr)

import json
import logging
import os
import time

import boto3
from botocore.exceptions import ClientError

logger = logging.getLogger()
logger.setLevel(logging.INFO)

# ---------------------------------------------------------------------------
# Clients — created once at cold-start, reused across warm invocations
# ---------------------------------------------------------------------------
ec2           = boto3.client("ec2",           region_name="us-east-1")
ssm           = boto3.client("ssm",           region_name="us-east-1")
autoscaling   = boto3.client("autoscaling",   region_name="us-east-1")
cloudwatch    = boto3.client("cloudwatch",    region_name="us-east-1")

ASG_NAME      = os.environ.get("ASG_NAME",      "TechStream-ASG")
SSM_DOCUMENT  = os.environ.get("SSM_DOCUMENT",  "AWS-RunShellScript")
RESTART_CMD   = os.environ.get("RESTART_CMD",   "systemctl restart techstream-app")
MAX_SCALE_OUT = int(os.environ.get("MAX_SCALE_OUT", "4"))   # hard ceiling


# ---------------------------------------------------------------------------
# Helper: discover running instances with TechStream tags
# ---------------------------------------------------------------------------
def _find_instances() -> list[str]:
    paginator = ec2.get_paginator("describe_instances")
    instance_ids = []
    for page in paginator.paginate(
        Filters=[
            {"Name": "tag:Project",      "Values": ["TechStream"]},
            {"Name": "tag:Lab",          "Values": ["SelfHealing"]},
            {"Name": "instance-state-name", "Values": ["running"]},
        ]
    ):
        for reservation in page["Reservations"]:
            for inst in reservation["Instances"]:
                instance_ids.append(inst["InstanceId"])
    logger.info(json.dumps({"action": "discover_instances", "found": instance_ids}))
    return instance_ids


# ---------------------------------------------------------------------------
# Remediation 1 — SSM RunCommand restart
# ---------------------------------------------------------------------------
def _ssm_restart(instance_ids: list[str]) -> dict[str, bool]:
    """
    Returns {instance_id: True/False} where True means the command was
    delivered and completed successfully.
    """
    results: dict[str, bool] = {}

    if not instance_ids:
        return results

    try:
        response = ssm.send_command(
            InstanceIds=instance_ids,
            DocumentName=SSM_DOCUMENT,
            Parameters={"commands": [RESTART_CMD]},
            Comment="TechStream auto-remediation — restart techstream-app",
            TimeoutSeconds=60,
        )
        command_id = response["Command"]["CommandId"]
        logger.info(json.dumps({
            "action": "ssm_send_command",
            "command_id": command_id,
            "targets": instance_ids,
        }))
    except ClientError as exc:
        logger.error(json.dumps({
            "action": "ssm_send_command_failed",
            "error": str(exc),
            "targets": instance_ids,
        }))
        return {iid: False for iid in instance_ids}

    # Poll for completion (max 90 s)
    deadline = time.time() + 90
    pending  = set(instance_ids)

    while pending and time.time() < deadline:
        time.sleep(5)
        for iid in list(pending):
            try:
                inv = ssm.get_command_invocation(
                    CommandId=command_id,
                    InstanceId=iid,
                )
                status = inv["StatusDetails"]
                if status in ("Success", "Failed", "Cancelled", "TimedOut"):
                    results[iid] = (status == "Success")
                    pending.discard(iid)
                    logger.info(json.dumps({
                        "action": "ssm_result",
                        "instance_id": iid,
                        "status": status,
                    }))
            except ClientError:
                pass

    # Anything still pending after 90 s is treated as a failure
    for iid in pending:
        results[iid] = False
        logger.warning(json.dumps({
            "action": "ssm_timeout",
            "instance_id": iid,
        }))

    return results


# ---------------------------------------------------------------------------
# Remediation 2 — ASG scale-out fallback
# ---------------------------------------------------------------------------
def _asg_scale_out() -> bool:
    try:
        asg_info = autoscaling.describe_auto_scaling_groups(
            AutoScalingGroupNames=[ASG_NAME]
        )["AutoScalingGroups"]

        if not asg_info:
            logger.error(json.dumps({"action": "asg_not_found", "asg_name": ASG_NAME}))
            return False

        asg          = asg_info[0]
        current      = asg["DesiredCapacity"]
        maximum      = asg["MaxSize"]
        new_desired  = min(current + 1, maximum, MAX_SCALE_OUT)

        if new_desired <= current:
            logger.warning(json.dumps({
                "action": "asg_scale_out_skipped",
                "reason": "already_at_max",
                "current": current,
                "maximum": maximum,
            }))
            return False

        autoscaling.set_desired_capacity(
            AutoScalingGroupName=ASG_NAME,
            DesiredCapacity=new_desired,
            HonorCooldown=False,   # override cooldown — we need capacity now
        )
        logger.info(json.dumps({
            "action": "asg_scale_out",
            "asg_name": ASG_NAME,
            "from": current,
            "to": new_desired,
        }))
        return True

    except ClientError as exc:
        logger.error(json.dumps({"action": "asg_scale_out_failed", "error": str(exc)}))
        return False


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------
def handler(event, context):
    logger.info(json.dumps({"action": "triggered", "event": event}))

    alarm_name  = event.get("detail", {}).get("alarmName", "unknown")
    alarm_state = event.get("detail", {}).get("state", {}).get("value", "unknown")

    logger.info(json.dumps({
        "action": "alarm_received",
        "alarm_name": alarm_name,
        "alarm_state": alarm_state,
    }))

    # Only act on ALARM transitions (EventBridge rule filters this, but be defensive)
    if alarm_state != "ALARM":
        logger.info(json.dumps({"action": "no_op", "reason": "state_not_alarm"}))
        return {"status": "no_op"}

    instance_ids = _find_instances()
    overall_success = False

    # --- Primary: SSM restart on every running instance ---
    if instance_ids:
        ssm_results = _ssm_restart(instance_ids)
        failed_ids  = [iid for iid, ok in ssm_results.items() if not ok]

        if not failed_ids:
            overall_success = True
            logger.info(json.dumps({"action": "ssm_all_succeeded"}))
        else:
            logger.warning(json.dumps({
                "action": "ssm_partial_failure",
                "failed_instances": failed_ids,
            }))
    else:
        logger.warning(json.dumps({"action": "no_instances_found"}))
        failed_ids = []

    # --- Fallback: ASG scale-out if any SSM attempt failed or no instances found ---
    if not overall_success:
        asg_ok = _asg_scale_out()
        overall_success = asg_ok

    result = {
        "status": "remediated" if overall_success else "failed",
        "alarm_name": alarm_name,
        "instances_targeted": instance_ids,
    }
    logger.info(json.dumps({"action": "complete", "result": result}))
    return result
