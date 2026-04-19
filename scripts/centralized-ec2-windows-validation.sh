#!/usr/bin/env bash
set -Eeuo pipefail

log() {
  echo "[$(date -u +'%Y-%m-%dT%H:%M:%SZ')] $*"
}

fail() {
  echo "ERROR: $*" >&2
  exit 1
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || fail "Required command not found: $1"
}

require_cmd aws
require_cmd python3

REGION="${REGION:-${AWS_REGION:-}}"
INSTANCE_ID="${INSTANCE_ID:-}"
SERVER_NAME="${SERVER_NAME:-}"
EXPECTED_TIMEZONE="${EXPECTED_TIMEZONE:-}"
EXPECTED_DOMAIN="${EXPECTED_DOMAIN:-}"
EXPECTED_HOSTNAME="${EXPECTED_HOSTNAME:-}"
POLL_SECONDS="${POLL_SECONDS:-5}"
MAX_POLLS="${MAX_POLLS:-24}"

[ -n "$REGION" ] || fail "REGION is required"

if [ -z "$INSTANCE_ID" ] && [ -z "$SERVER_NAME" ]; then
  fail "Provide either INSTANCE_ID or SERVER_NAME"
fi

TMP_DIR="$(mktemp -d)"
cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

log "Validating AWS caller identity..."
aws sts get-caller-identity --output json >/dev/null 2>"$TMP_DIR/sts.err" || {
  cat "$TMP_DIR/sts.err" >&2
  fail "Unable to authenticate to AWS"
}

log "Resolving target instance..."

if [ -n "$INSTANCE_ID" ]; then
  DESCRIBE_JSON="$(aws ec2 describe-instances \
    --region "$REGION" \
    --instance-ids "$INSTANCE_ID" \
    --output json 2>"$TMP_DIR/describe.err")" || {
      cat "$TMP_DIR/describe.err" >&2
      fail "aws ec2 describe-instances failed"
    }
else
  DESCRIBE_JSON="$(aws ec2 describe-instances \
    --region "$REGION" \
    --filters "Name=tag:Name,Values=$SERVER_NAME" \
              "Name=instance-state-name,Values=pending,running,stopping,stopped" \
    --output json 2>"$TMP_DIR/describe.err")" || {
      cat "$TMP_DIR/describe.err" >&2
      fail "aws ec2 describe-instances failed"
    }
fi

[ -n "$DESCRIBE_JSON" ] || fail "aws ec2 describe-instances returned empty output"

TARGET_JSON="$(printf '%s' "$DESCRIBE_JSON" | python3 -c '
import json, sys

instance_id = sys.argv[1]
server_name = sys.argv[2]

try:
    data = json.load(sys.stdin)
except json.JSONDecodeError as exc:
    print(f"Invalid JSON from describe-instances: {exc}", file=sys.stderr)
    sys.exit(1)

instances = []
for reservation in data.get("Reservations", []):
    instances.extend(reservation.get("Instances", []))

if not instances:
    print("No instances returned from EC2 describe call", file=sys.stderr)
    sys.exit(1)

def name_tag(instance):
    for tag in instance.get("Tags", []):
        if tag.get("Key") == "Name":
            return tag.get("Value", "")
    return ""

if instance_id:
    matches = [i for i in instances if i.get("InstanceId") == instance_id]
else:
    matches = [i for i in instances if name_tag(i) == server_name]
    if len(matches) > 1:
        print("More than one instance matched SERVER_NAME; use INSTANCE_ID instead", file=sys.stderr)
        sys.exit(1)

if not matches:
    print("Instance not found", file=sys.stderr)
    sys.exit(1)

instance = matches[0]
result = {
    "InstanceId": instance.get("InstanceId", ""),
    "Name": name_tag(instance),
    "State": instance.get("State", {}).get("Name", "unknown"),
    "PlatformDetails": instance.get("PlatformDetails") or instance.get("Platform") or "",
    "PrivateIpAddress": instance.get("PrivateIpAddress", "")
}
print(json.dumps(result))
' "${INSTANCE_ID:-}" "${SERVER_NAME:-}")" || fail "instance not found"

TARGET_INSTANCE_ID="$(printf '%s' "$TARGET_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin)["InstanceId"])')"
TARGET_NAME="$(printf '%s' "$TARGET_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin)["Name"])')"
TARGET_STATE="$(printf '%s' "$TARGET_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin)["State"])')"
TARGET_PLATFORM="$(printf '%s' "$TARGET_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin)["PlatformDetails"])')"
TARGET_PRIVATE_IP="$(printf '%s' "$TARGET_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin)["PrivateIpAddress"])')"

log "Resolved instance: id=$TARGET_INSTANCE_ID name=${TARGET_NAME:-N/A} state=$TARGET_STATE platform=${TARGET_PLATFORM:-N/A} private_ip=${TARGET_PRIVATE_IP:-N/A}"

[ "$TARGET_STATE" = "running" ] || fail "Target instance must be running for SSM validation"
printf '%s' "$TARGET_PLATFORM" | grep -iq "windows" || fail "Target instance is not Windows"

log "Building SSM command payload..."
python3 - "$TMP_DIR/ssm-parameters.json" <<'PY'
import json, sys

path = sys.argv[1]
commands = [
    "$ErrorActionPreference = 'Stop'",
    "$tz = (Get-TimeZone).Id",
    "$domain = (Get-CimInstance Win32_ComputerSystem).Domain",
    "$hostname = $env:COMPUTERNAME",
    "$result = [ordered]@{ Hostname = $hostname; Domain = $domain; TimeZone = $tz }",
    "$result | ConvertTo-Json -Compress"
]
with open(path, "w", encoding="utf-8") as f:
    json.dump({"commands": commands}, f)
PY

log "Sending SSM command..."
COMMAND_ID="$(aws ssm send-command \
  --region "$REGION" \
  --document-name "AWS-RunPowerShellScript" \
  --instance-ids "$TARGET_INSTANCE_ID" \
  --comment "Centralized Windows EC2 validation" \
  --parameters "file://$TMP_DIR/ssm-parameters.json" \
  --query "Command.CommandId" \
  --output text 2>"$TMP_DIR/send.err")" || {
    cat "$TMP_DIR/send.err" >&2
    fail "Failed to send SSM command"
  }

[ -n "$COMMAND_ID" ] && [ "$COMMAND_ID" != "None" ] || fail "SSM did not return a command id"
log "SSM command id: $COMMAND_ID"

STATUS=""
for ((i=1; i<=MAX_POLLS; i++)); do
  STATUS="$(aws ssm get-command-invocation \
    --region "$REGION" \
    --command-id "$COMMAND_ID" \
    --instance-id "$TARGET_INSTANCE_ID" \
    --query "Status" \
    --output text 2>"$TMP_DIR/invoke.err")" || true

  case "$STATUS" in
    Success)
      log "SSM command completed successfully"
      break
      ;;
    Pending|InProgress|Delayed|"")
      log "Waiting for SSM command... attempt $i/$MAX_POLLS"
      sleep "$POLL_SECONDS"
      ;;
    Cancelled|Cancelling|TimedOut|Failed)
      log "SSM command finished with status: $STATUS"
      break
      ;;
    *)
      log "SSM command returned status: $STATUS"
      sleep "$POLL_SECONDS"
      ;;
  esac
done

INVOCATION_JSON="$(aws ssm get-command-invocation \
  --region "$REGION" \
  --command-id "$COMMAND_ID" \
  --instance-id "$TARGET_INSTANCE_ID" \
  --output json 2>"$TMP_DIR/final-invoke.err")" || {
    cat "$TMP_DIR/final-invoke.err" >&2
    fail "Failed to get SSM command invocation details"
  }

FINAL_STATUS="$(printf '%s' "$INVOCATION_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("Status",""))')"
STDOUT_CONTENT="$(printf '%s' "$INVOCATION_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("StandardOutputContent",""))')"
STDERR_CONTENT="$(printf '%s' "$INVOCATION_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("StandardErrorContent",""))')"

if [ "$FINAL_STATUS" != "Success" ]; then
  [ -n "$STDERR_CONTENT" ] && printf '%s\n' "$STDERR_CONTENT" >&2
  fail "SSM command did not succeed. Final status: $FINAL_STATUS"
fi

[ -n "$STDOUT_CONTENT" ] || fail "SSM command succeeded but returned empty output"

RESULT_JSON="$(printf '%s' "$STDOUT_CONTENT" | python3 -c '
import json, sys

raw = sys.stdin.read().strip()
try:
    data = json.loads(raw)
except json.JSONDecodeError:
    print(raw, file=sys.stderr)
    sys.exit(1)

required = ["Hostname", "Domain", "TimeZone"]
for key in required:
    if key not in data:
        print(f"Missing expected key in SSM output: {key}", file=sys.stderr)
        sys.exit(1)

print(json.dumps(data))
')" || fail "SSM output was not valid JSON"

ACTUAL_HOSTNAME="$(printf '%s' "$RESULT_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin)["Hostname"])')"
ACTUAL_DOMAIN="$(printf '%s' "$RESULT_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin)["Domain"])')"
ACTUAL_TIMEZONE="$(printf '%s' "$RESULT_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin)["TimeZone"])')"

log "Collected values from instance:"
echo "  Hostname : $ACTUAL_HOSTNAME"
echo "  Domain   : $ACTUAL_DOMAIN"
echo "  TimeZone : $ACTUAL_TIMEZONE"

FAILURES=0

compare_exact() {
  local label="$1"
  local expected="$2"
  local actual="$3"

  if [ -z "$expected" ]; then
    echo "SKIP - $label (no expected value supplied)"
    return 0
  fi

  if [ "$expected" = "$actual" ]; then
    echo "PASS - $label matches expected value"
  else
    echo "FAIL - $label expected '$expected' but got '$actual'"
    FAILURES=$((FAILURES + 1))
  fi
}

compare_case_insensitive() {
  local label="$1"
  local expected="$2"
  local actual="$3"

  if [ -z "$expected" ]; then
    echo "SKIP - $label (no expected value supplied)"
    return 0
  fi

  if [ "${expected,,}" = "${actual,,}" ]; then
    echo "PASS - $label matches expected value"
  else
    echo "FAIL - $label expected '$expected' but got '$actual'"
    FAILURES=$((FAILURES + 1))
  fi
}

compare_case_insensitive "Hostname" "$EXPECTED_HOSTNAME" "$ACTUAL_HOSTNAME"
compare_case_insensitive "Domain" "$EXPECTED_DOMAIN" "$ACTUAL_DOMAIN"
compare_exact "TimeZone" "$EXPECTED_TIMEZONE" "$ACTUAL_TIMEZONE"

if [ "$FAILURES" -gt 0 ]; then
  fail "Validation completed with $FAILURES failure(s)"
fi

log "Validation completed successfully"
