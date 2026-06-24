#!/bin/bash
# userdata.sh — EC2 UserData for TechStream Self-Healing lab
# Runs as root on first boot (Amazon Linux 2).
# Installs Python 3.12, Flask, the CloudWatch agent, wires up the app as a
# systemd service, and starts the agent with the bundled config.

set -euo pipefail
exec > >(tee /var/log/userdata.log | logger -t userdata -s 2>/dev/console) 2>&1

REGION="us-east-1"
APP_DIR="/opt/techstream"
APP_USER="techstream"
SERVICE_NAME="techstream-app"
LOG_FILE="/var/log/app.log"
CW_CONFIG_PATH="/opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json"

echo "[$(date -u +%FT%TZ)] === TechStream UserData START ==="

# ---------------------------------------------------------------------------
# 1. System packages
# ---------------------------------------------------------------------------
yum update -y
yum install -y \
    python3.12 \
    python3.12-pip \
    curl \
    jq \
    stress-ng          # needed by chaos.sh (Step 4)

# ---------------------------------------------------------------------------
# 2. CloudWatch Agent
# ---------------------------------------------------------------------------
yum install -y amazon-cloudwatch-agent

# ---------------------------------------------------------------------------
# 3. Application user & directory
# ---------------------------------------------------------------------------
useradd --system --no-create-home --shell /sbin/nologin "$APP_USER" || true
mkdir -p "$APP_DIR"

# Pull app.py from the instance metadata (easiest for a lab).
# In production you would use S3 or CodeDeploy.
# We embed the file via cfn-init or SSM; here we copy from /tmp if pre-staged,
# otherwise write a minimal placeholder so systemd starts cleanly.
if [[ -f /tmp/app.py ]]; then
    cp /tmp/app.py "$APP_DIR/app.py"
else
    # Placeholder — replace with real app.py via SSM SendCommand or cfn-init
    cat > "$APP_DIR/app.py" << 'PLACEHOLDER'
from flask import Flask, jsonify
app = Flask(__name__)

@app.route("/health")
def health():
    return jsonify(status="ok"), 200

if __name__ == "__main__":
    app.run(host="0.0.0.0", port=5000)
PLACEHOLDER
fi

chown -R "$APP_USER:$APP_USER" "$APP_DIR"

# ---------------------------------------------------------------------------
# 4. Python virtual environment + Flask
# ---------------------------------------------------------------------------
python3.12 -m venv "$APP_DIR/venv"
"$APP_DIR/venv/bin/pip" install --quiet --upgrade pip
"$APP_DIR/venv/bin/pip" install --quiet flask

# ---------------------------------------------------------------------------
# 5. Log file (writable by app user, readable by cwagent)
# ---------------------------------------------------------------------------
touch "$LOG_FILE"
chown "$APP_USER:$APP_USER" "$LOG_FILE"
chmod 644 "$LOG_FILE"

# ---------------------------------------------------------------------------
# 6. systemd service
# ---------------------------------------------------------------------------
cat > /etc/systemd/system/${SERVICE_NAME}.service << EOF
[Unit]
Description=TechStream Web Server
After=network.target

[Service]
User=${APP_USER}
WorkingDirectory=${APP_DIR}
ExecStart=${APP_DIR}/venv/bin/python ${APP_DIR}/app.py
Restart=on-failure
RestartSec=5s
StandardOutput=append:${LOG_FILE}
StandardError=append:${LOG_FILE}

# Tag the process so SSM Run Command can target it by name
Environment="APP_NAME=techstream-app"

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable "$SERVICE_NAME"
systemctl start  "$SERVICE_NAME"

# ---------------------------------------------------------------------------
# 7. CloudWatch agent config (written inline; Step 2 also ships the JSON file
#    separately so Terraform/CloudFormation can inject it via SSM Parameter)
# ---------------------------------------------------------------------------
mkdir -p "$(dirname "$CW_CONFIG_PATH")"

cat > "$CW_CONFIG_PATH" << 'CWCONFIG'
{
  "agent": {
    "metrics_collection_interval": 60,
    "run_as_user": "cwagent",
    "logfile": "/opt/aws/amazon-cloudwatch-agent/logs/amazon-cloudwatch-agent.log"
  },
  "metrics": {
    "namespace": "TechStream/WebServer",
    "append_dimensions": {
      "InstanceId": "${aws:InstanceId}",
      "AutoScalingGroupName": "${aws:AutoScalingGroupName}"
    },
    "aggregation_dimensions": [["AutoScalingGroupName"]],
    "metrics_collected": {
      "cpu": {
        "measurement": ["cpu_usage_idle"],
        "metrics_collection_interval": 60,
        "totalcpu": true
      },
      "mem": {
        "measurement": ["mem_used_percent"],
        "metrics_collection_interval": 60
      },
      "disk": {
        "measurement": ["disk_used_percent"],
        "metrics_collection_interval": 60,
        "resources": ["/"]
      }
    }
  },
  "logs": {
    "logs_collected": {
      "files": {
        "collect_list": [
          {
            "file_path": "/var/log/app.log",
            "log_group_name": "/techstream/app",
            "log_stream_name": "{instance_id}",
            "timezone": "UTC",
            "timestamp_format": "%Y-%m-%dT%H:%M:%S",
            "multi_line_start_pattern": "^\\{"
          }
        ]
      }
    },
    "log_stream_name": "default",
    "force_flush_interval": 15
  }
}
CWCONFIG

# ---------------------------------------------------------------------------
# 8. Start CloudWatch agent with the config
# ---------------------------------------------------------------------------
/opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent-ctl \
    -a fetch-config \
    -m ec2 \
    -s \
    -c "file:${CW_CONFIG_PATH}"

# ---------------------------------------------------------------------------
# 9. EC2 instance tags (requires IMDSv2 + instance profile with ec2:CreateTags)
# ---------------------------------------------------------------------------
TOKEN=$(curl -sX PUT "http://169.254.169.254/latest/api/token" \
    -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")
INSTANCE_ID=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" \
    http://169.254.169.254/latest/meta-data/instance-id)

aws ec2 create-tags \
    --region "$REGION" \
    --resources "$INSTANCE_ID" \
    --tags \
        Key=Project,Value=TechStream \
        Key=Lab,Value=SelfHealing \
        Key=Name,Value=TechStream-WebServer \
    || echo "WARN: tagging failed (check instance profile permissions)"

echo "[$(date -u +%FT%TZ)] === TechStream UserData END ==="
