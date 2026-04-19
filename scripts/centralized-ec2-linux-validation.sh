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

PASS_COUNT=0
FAIL_COUNT=0
SKIP_COUNT=0
TOTAL_CHECKS=0
VALIDATION_FAILURES=0

declare -a PASSED_CHECKS=()
declare -a FAILED_CHECKS=()
declare -a SKIPPED_CHECKS=()

record_pass() {
  echo "PASS - $1"
  PASS_COUNT=$((PASS_COUNT + 1))
  TOTAL_CHECKS=$((TOTAL_CHECKS + 1))
  PASSED_CHECKS+=("$1")
}

record_skip() {
  echo "SKIP - $1"
  SKIP_COUNT=$((SKIP_COUNT + 1))
  TOTAL_CHECKS=$((TOTAL_CHECKS + 1))
  SKIPPED_CHECKS+=("$1")
}

record_fail() {
  echo "FAIL - $1"
  FAIL_COUNT=$((FAIL_COUNT + 1))
  TOTAL_CHECKS=$((TOTAL_CHECKS + 1))
  VALIDATION_FAILURES=$((VALIDATION_FAILURES + 1))
  FAILED_CHECKS+=("$1")
}

compare_exact() {
  local label="$1"
  local expected="$2"
  local actual="$3"

  if [ -z "$expected" ]; then
    record_skip "$label (no expected value supplied)"
    return 0
  fi

  if [ "$expected" = "$actual" ]; then
    record_pass "$label matches expected value"
  else
    record_fail "$label expected '$expected' but got '$actual'"
  fi
}

compare_case_insensitive() {
  local label="$1"
  local expected="$2"
  local actual="$3"

  if [ -z "$expected" ]; then
    record_skip "$label (no expected value supplied)"
    return 0
  fi

  if [ "${expected,,}" = "${actual,,}" ]; then
    record_pass "$label matches expected value"
  else
    record_fail "$label expected '$expected' but got '$actual'"
  fi
}

is_true() {
  case "${1,,}" in
    true|1|yes|y) return 0 ;;
    *) return 1 ;;
  esac
}

require_cmd aws
require_cmd jq
require_cmd awk
require_cmd python3

REGION="${REGION:-${AWS_REGION:-}}"
INSTANCE_ID="${INSTANCE_ID:-}"
SERVER_NAME="${SERVER_NAME:-}"
EXPECTED_TIMEZONE="${EXPECTED_TIMEZONE:-}"
EXPECTED_DOMAIN="${EXPECTED_DOMAIN:-}"
EXPECTED_HOSTNAME="${EXPECTED_HOSTNAME:-}"
DNS_NAME_TO_RESOLVE="${DNS_NAME_TO_RESOLVE:-}"
REQUIRED_SERVICES_CSV="${REQUIRED_SERVICES_CSV:-}"
FAIL_ON_VALIDATION_ISSUES="${FAIL_ON_VALIDATION_ISSUES:-false}"
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
ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text 2>"$TMP_DIR/sts.err")" || {
  cat "$TMP_DIR/sts.err" >&2
  fail "Unable to authenticate to AWS"
}

log "Resolving target instance..."

if [ -n "$INSTANCE_ID" ]; then
  INSTANCE_JSON="$(aws ec2 describe-instances \
    --region "$REGION" \
    --instance-ids "$INSTANCE_ID" \
    --output json 2>"$TMP_DIR/describe.err")" || {
      cat "$TMP_DIR/describe.err" >&2
      fail "aws ec2 describe-instances failed"
    }

  MATCHED_INSTANCE="$(printf '%s' "$INSTANCE_JSON" | jq -c --arg iid "$INSTANCE_ID" '
    [ .Reservations[].Instances[] | select(.InstanceId == $iid) ][0]
  ')" || fail "Failed to parse EC2 describe output"
else
  INSTANCE_JSON="$(aws ec2 describe-instances \
    --region "$REGION" \
    --output json 2>"$TMP_DIR/describe.err")" || {
      cat "$TMP_DIR/describe.err" >&2
      fail "aws ec2 describe-instances failed"
    }

  MATCHED_INSTANCE="$(printf '%s' "$INSTANCE_JSON" | jq -c --arg name "${SERVER_NAME,,}" '
    [ .Reservations[].Instances[]
      | select(
          .State.Name == "running"
          and any(.Tags[]?; .Key == "Name" and ((.Value // "") | ascii_downcase) == $name)
        )
    ][0]
  ')" || fail "Failed to parse EC2 describe output"
fi

if [ -z "$MATCHED_INSTANCE" ] || [ "$MATCHED_INSTANCE" = "null" ]; then
  fail "No matching instance found"
fi

TARGET_INSTANCE_ID="$(printf '%s' "$MATCHED_INSTANCE" | jq -r '.InstanceId')"
TARGET_NAME="$(printf '%s' "$MATCHED_INSTANCE" | jq -r '[.Tags[]? | select(.Key=="Name") | .Value][0] // ""')"
TARGET_STATE="$(printf '%s' "$MATCHED_INSTANCE" | jq -r '.State.Name // "unknown"')"
TARGET_PLATFORM="$(printf '%s' "$MATCHED_INSTANCE" | jq -r '.PlatformDetails // .Platform // ""')"

VPC_ID="$(printf '%s' "$MATCHED_INSTANCE" | jq -r '.VpcId // ""')"
SUBNET_ID="$(printf '%s' "$MATCHED_INSTANCE" | jq -r '.SubnetId // ""')"
INSTANCE_TYPE="$(printf '%s' "$MATCHED_INSTANCE" | jq -r '.InstanceType // ""')"
EBS_COUNT="$(printf '%s' "$MATCHED_INSTANCE" | jq -r '.BlockDeviceMappings | length')"

PRIMARY_IP="$(printf '%s' "$MATCHED_INSTANCE" | jq -r '.NetworkInterfaces[0].PrivateIpAddress // .PrivateIpAddress // "N/A"')"
SECONDARY_IPS="$(printf '%s' "$MATCHED_INSTANCE" | jq -r '[.NetworkInterfaces[0].PrivateIpAddresses[]? | select(.Primary==false) | .PrivateIpAddress] | join(",")')"
if [ -z "$SECONDARY_IPS" ]; then
  SECONDARY_IPS="None"
fi

SG_IDS="$(printf '%s' "$MATCHED_INSTANCE" | jq -r '[.SecurityGroups[]?.GroupId] | join(",")')"
SG_NAMES="$(printf '%s' "$MATCHED_INSTANCE" | jq -r '[.SecurityGroups[]?.GroupName] | join(",")')"
[ -n "$SG_IDS" ] || SG_IDS="None"
[ -n "$SG_NAMES" ] || SG_NAMES="None"

VPC_NAME="$(aws ec2 describe-tags \
  --filters "Name=resource-id,Values=$VPC_ID" "Name=key,Values=Name" \
  --region "$REGION" \
  --query "Tags[0].Value" \
  --output text 2>/dev/null || true)"
if [ -z "$VPC_NAME" ] || [ "$VPC_NAME" = "None" ]; then
  VPC_NAME="(No Name tag)"
fi

SUBNET_NAME="$(aws ec2 describe-tags \
  --filters "Name=resource-id,Values=$SUBNET_ID" "Name=key,Values=Name" \
  --region "$REGION" \
  --query "Tags[0].Value" \
  --output text 2>/dev/null || true)"
if [ -z "$SUBNET_NAME" ] || [ "$SUBNET_NAME" = "None" ]; then
  SUBNET_NAME="(No Name tag)"
fi

INSTANCE_TYPE_JSON="$(aws ec2 describe-instance-types \
  --instance-types "$INSTANCE_TYPE" \
  --region "$REGION" \
  --output json 2>"$TMP_DIR/itype.err")" || {
    cat "$TMP_DIR/itype.err" >&2
    fail "aws ec2 describe-instance-types failed"
  }

VCPU="$(printf '%s' "$INSTANCE_TYPE_JSON" | jq -r '.InstanceTypes[0].VCpuInfo.DefaultVCpus // "N/A"')"
RAM_MiB="$(printf '%s' "$INSTANCE_TYPE_JSON" | jq -r '.InstanceTypes[0].MemoryInfo.SizeInMiB // 0')"
RAM_GiB="$(awk "BEGIN {printf \"%.2f\", $RAM_MiB/1024}")"

HEALTH_JSON="$(aws ec2 describe-instance-status \
  --instance-ids "$TARGET_INSTANCE_ID" \
  --include-all-instances \
  --region "$REGION" \
  --output json 2>"$TMP_DIR/health.err")" || {
    cat "$TMP_DIR/health.err" >&2
    fail "aws ec2 describe-instance-status failed"
  }

SYSTEM_STATUS="$(printf '%s' "$HEALTH_JSON" | jq -r '.InstanceStatuses[0].SystemStatus.Status // "N/A"')"
INSTANCE_STATUS="$(printf '%s' "$HEALTH_JSON" | jq -r '.InstanceStatuses[0].InstanceStatus.Status // "N/A"')"

log "Server attributes"
printf "\n%-20s %-15s %-20s %-15s %-20s %-20s %-15s %-10s %-10s %-10s %-10s %-25s %-30s %-15s %-15s %-30s\n" \
"Server Name" "Region" "Instance ID" "Account ID" "VPC Name" "Subnet Name" "Primary IP" "EBS Cnt" "Type" "vCPUs" "RAM(GB)" "SG Names" "SG IDs" "SysHealth" "InstHealth" "Sec. IPs"

echo "--------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------"

printf "%-20s %-15s %-20s %-15s %-20s %-20s %-15s %-10s %-10s %-10s %-10s %-25s %-30s %-15s %-15s %-30s\n" \
"${TARGET_NAME:-N/A}" "$REGION" "$TARGET_INSTANCE_ID" "$ACCOUNT_ID" "$VPC_NAME" "$SUBNET_NAME" "$PRIMARY_IP" "$EBS_COUNT" "$INSTANCE_TYPE" "$VCPU" "$RAM_GiB" "$SG_NAMES" "$SG_IDS" "$SYSTEM_STATUS" "$INSTANCE_STATUS" "$SECONDARY_IPS"

echo -e "\nDevice Name     Volume ID            Type       Size(GB)   IOPS       Encrypted"
echo    "--------------------------------------------------------------------------------"

BLOCK_DEVICE_ROWS="$(printf '%s' "$MATCHED_INSTANCE" | jq -r '.BlockDeviceMappings[]? | [.DeviceName, .Ebs.VolumeId] | @tsv')"
if [ -z "$BLOCK_DEVICE_ROWS" ]; then
  echo "No EBS volumes found."
else
  while IFS=$'\t' read -r device volumeid; do
    [ -n "$volumeid" ] || continue
    VOLUME_JSON="$(aws ec2 describe-volumes --volume-ids "$volumeid" --region "$REGION" --output json 2>"$TMP_DIR/volume-$volumeid.err")" || {
      cat "$TMP_DIR/volume-$volumeid.err" >&2
      fail "aws ec2 describe-volumes failed for $volumeid"
    }

    VTYPE="$(printf '%s' "$VOLUME_JSON" | jq -r '.Volumes[0].VolumeType // "N/A"')"
    VSIZE="$(printf '%s' "$VOLUME_JSON" | jq -r '.Volumes[0].Size // "N/A"')"
    VIOPS="$(printf '%s' "$VOLUME_JSON" | jq -r '.Volumes[0].Iops // "N/A"')"
    VENCRYPTED="$(printf '%s' "$VOLUME_JSON" | jq -r '.Volumes[0].Encrypted // "N/A"')"

    printf "%-15s %-20s %-10s %-10s %-10s %-10s\n" "$device" "$volumeid" "$VTYPE" "$VSIZE" "$VIOPS" "$VENCRYPTED"
  done <<< "$BLOCK_DEVICE_ROWS"
fi

echo -e "\nTag Key                        Tag Value"
echo    "----------------------------------------------------------"

TAG_ROWS="$(printf '%s' "$MATCHED_INSTANCE" | jq -r '.Tags[]? | [.Key, .Value] | @tsv')"
if [ -z "$TAG_ROWS" ]; then
  echo "No tags found."
else
  while IFS=$'\t' read -r key value; do
    printf "%-30s %-50s\n" "$key" "$value"
  done <<< "$TAG_ROWS"
fi

log "Running EC2-level checks..."
if [ "$TARGET_STATE" = "running" ]; then
  record_pass "Instance state is running"
else
  fail "Target instance must be running for SSM validation"
fi

if printf '%s' "$TARGET_PLATFORM" | grep -iq "windows"; then
  record_fail "Target instance is Windows, expected Linux"
else
  record_pass "Platform is Linux/Unix"
fi

if [ -n "$PRIMARY_IP" ] && [ "$PRIMARY_IP" != "N/A" ]; then
  record_pass "Primary private IP is populated"
else
  record_fail "Primary private IP is missing"
fi

compare_exact "InstanceId" "$INSTANCE_ID" "$TARGET_INSTANCE_ID"
compare_case_insensitive "EC2 Name tag" "$SERVER_NAME" "$TARGET_NAME"

log "Building SSM command payload..."
python3 - "$TMP_DIR/ssm-parameters.json" "$REQUIRED_SERVICES_CSV" "$DNS_NAME_TO_RESOLVE" <<'PY'
# Code Generated by Sidekick is for learning and experimentation purposes only.
import json
import sys

path = sys.argv[1]
required_services_csv = sys.argv[2]
dns_name = sys.argv[3]

script = f"""#!/usr/bin/env bash
set -euo pipefail

required_services_csv={json.dumps(required_services_csv)}
dns_name={json.dumps(dns_name)}

hostname_value="$(hostname 2>/dev/null || true)"
short_hostname="$(hostname -s 2>/dev/null || true)"
[ -n "$short_hostname" ] && hostname_value="$short_hostname"

domain_value="$(hostname -d 2>/dev/null || true)"
if [ -z "$domain_value" ]; then
  domain_value="$(dnsdomainname 2>/dev/null || true)"
fi
if [ -z "$domain_value" ]; then
  fqdn="$(hostname -f 2>/dev/null || true)"
  if [ -n "$fqdn" ] && [ "$fqdn" != "$hostname_value" ]; then
    domain_value="${{fqdn#*.}}"
  fi
fi

timezone_value=""
if command -v timedatectl >/dev/null 2>&1; then
  timezone_value="$(timedatectl show -p Timezone --value 2>/dev/null || true)"
fi
if [ -z "$timezone_value" ] && [ -f /etc/timezone ]; then
  timezone_value="$(cat /etc/timezone 2>/dev/null || true)"
fi
if [ -z "$timezone_value" ] && [ -L /etc/localtime ]; then
  timezone_value="$(readlink /etc/localtime 2>/dev/null | sed 's#^.*/zoneinfo/##' || true)"
fi

os_name=""
os_version=""
os_pretty=""
if [ -f /etc/os-release ]; then
  . /etc/os-release
  os_name="${{NAME:-}}"
  os_version="${{VERSION_ID:-}}"
  os_pretty="${{PRETTY_NAME:-}}"
fi

last_boot=""
if command -v uptime >/dev/null 2>&1; then
  last_boot="$(uptime -s 2>/dev/null || true)"
fi

dns_json="[]"
if [ -n "$dns_name" ]; then
  if command -v getent >/dev/null 2>&1; then
    dns_json="$(getent ahosts "$dns_name" 2>/dev/null | awk '{{print $1}}' | sort -u | python3 -c 'import json,sys; print(json.dumps([line.strip() for line in sys.stdin if line.strip()]))')"
  elif command -v host >/dev/null 2>&1; then
    dns_json="$(host "$dns_name" 2>/dev/null | awk '/has address/ {{print $4}}' | sort -u | python3 -c 'import json,sys; print(json.dumps([line.strip() for line in sys.stdin if line.strip()]))')"
  fi
fi

services_json="[]"
if [ -n "$required_services_csv" ]; then
  services_json="$(
    REQUIRED_SERVICES_CSV="$required_services_csv" python3 <<'PY2'
# Code Generated by Sidekick is for learning and experimentation purposes only.
import json
import os
import subprocess

services = [s.strip() for s in os.environ.get("REQUIRED_SERVICES_CSV", "").split(",") if s.strip()]
results = []

def run(cmd):
    return subprocess.run(cmd, capture_output=True, text=True)

for svc in services:
    candidates = [svc]
    if not svc.endswith(".service"):
        candidates.append(f"{svc}.service")

    found_name = svc
    exists = False
    status = "NotFound"

    for candidate in candidates:
        r = run(["systemctl", "status", candidate])
        if r.returncode in (0, 3, 4):
            found_name = candidate
            exists = True
            active = run(["systemctl", "is-active", candidate])
            status = (active.stdout.strip() or active.stderr.strip() or "unknown")
            break

    results.append({
        "Name": found_name,
        "Exists": exists,
        "Status": status
    })

print(json.dumps(results))
PY2
  )"
fi

python3 - <<PY3
# Code Generated by Sidekick is for learning and experimentation purposes only.
import json

result = {{
    "Hostname": {{"value": """$hostname_value"""}}["value"],
    "Domain": {{"value": """$domain_value"""}}["value"],
    "TimeZone": {{"value": """$timezone_value"""}}["value"],
    "OSName": {{"value": """$os_name"""}}["value"],
    "OSVersion": {{"value": """$os_version"""}}["value"],
    "OSPrettyName": {{"value": """$os_pretty"""}}["value"],
    "LastBootUpTime": {{"value": """$last_boot"""}}["value"],
    "RequiredServices": json.loads('''$services_json'''),
    "DnsNameQueried": {{"value": """$dns_name"""}}["value"],
    "DnsResolvedIPs": json.loads('''$dns_json''')
}}
print(json.dumps(result, separators=(",", ":")))
PY3
"""

with open(path, "w", encoding="utf-8") as f:
    json.dump({"commands": [script]}, f)
PY

log "Sending SSM command..."
COMMAND_ID="$(aws ssm send-command \
  --region "$REGION" \
  --document-name "AWS-RunShellScript" \
  --instance-ids "$TARGET_INSTANCE_ID" \
  --comment "Centralized Linux EC2 validation" \
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

FINAL_STATUS="$(printf '%s' "$INVOCATION_JSON" | jq -r '.Status // ""')"
STDOUT_CONTENT="$(printf '%s' "$INVOCATION_JSON" | jq -r '.StandardOutputContent // ""')"
STDERR_CONTENT="$(printf '%s' "$INVOCATION_JSON" | jq -r '.StandardErrorContent // ""')"

if [ "$FINAL_STATUS" != "Success" ]; then
  [ -n "$STDERR_CONTENT" ] && printf '%s\n' "$STDERR_CONTENT" >&2
  fail "SSM command did not succeed. Final status: $FINAL_STATUS"
fi

[ -n "$STDOUT_CONTENT" ] || fail "SSM command succeeded but returned empty output"

RESULT_JSON="$(printf '%s' "$STDOUT_CONTENT" | jq -c . 2>/dev/null)" || fail "SSM output was not valid JSON"

ACTUAL_HOSTNAME="$(printf '%s' "$RESULT_JSON" | jq -r '.Hostname // ""')"
ACTUAL_DOMAIN="$(printf '%s' "$RESULT_JSON" | jq -r '.Domain // ""')"
ACTUAL_TIMEZONE="$(printf '%s' "$RESULT_JSON" | jq -r '.TimeZone // ""')"
ACTUAL_OS_NAME="$(printf '%s' "$RESULT_JSON" | jq -r '.OSName // ""')"
ACTUAL_OS_VERSION="$(printf '%s' "$RESULT_JSON" | jq -r '.OSVersion // ""')"
ACTUAL_OS_PRETTY="$(printf '%s' "$RESULT_JSON" | jq -r '.OSPrettyName // ""')"
ACTUAL_LAST_BOOT="$(printf '%s' "$RESULT_JSON" | jq -r '.LastBootUpTime // ""')"

log "Collected in-instance OS details:"
echo "  Hostname       : ${ACTUAL_HOSTNAME:-N/A}"
echo "  Domain         : ${ACTUAL_DOMAIN:-N/A}"
echo "  TimeZone       : ${ACTUAL_TIMEZONE:-N/A}"
echo "  OS Name        : ${ACTUAL_OS_NAME:-N/A}"
echo "  OS Version     : ${ACTUAL_OS_VERSION:-N/A}"
echo "  OS Pretty Name : ${ACTUAL_OS_PRETTY:-N/A}"
echo "  LastBootUpTime : ${ACTUAL_LAST_BOOT:-N/A}"

echo "  DNS Query      : ${DNS_NAME_TO_RESOLVE:-N/A}"

mapfile -t DNS_IPS < <(printf '%s' "$RESULT_JSON" | jq -r '.DnsResolvedIPs[]?')
if [ "${#DNS_IPS[@]}" -eq 0 ]; then
  echo "  DNS Resolved IPs : none"
else
  echo "  DNS Resolved IPs :"
  for ip in "${DNS_IPS[@]}"; do
    echo "    - $ip"
  done
fi

echo "  Required services:"
mapfile -t SERVICE_ROWS < <(printf '%s' "$RESULT_JSON" | jq -r '.RequiredServices[]? | [.Name, (.Exists|tostring), .Status] | @tsv')
if [ "${#SERVICE_ROWS[@]}" -eq 0 ]; then
  echo "    - none requested"
else
  for row in "${SERVICE_ROWS[@]}"; do
    IFS=$'\t' read -r name exists status <<< "$row"
    [ -n "$name" ] || continue
    echo "    - $name : exists=$exists status=$status"
  done
fi

log "Running OS-level checks..."
compare_case_insensitive "Hostname" "$EXPECTED_HOSTNAME" "$ACTUAL_HOSTNAME"
compare_case_insensitive "Domain" "$EXPECTED_DOMAIN" "$ACTUAL_DOMAIN"
compare_exact "TimeZone" "$EXPECTED_TIMEZONE" "$ACTUAL_TIMEZONE"

if [ -n "$DNS_NAME_TO_RESOLVE" ]; then
  if [ "${#DNS_IPS[@]}" -eq 0 ]; then
    record_fail "DNS name '$DNS_NAME_TO_RESOLVE' did not resolve on the instance"
  else
    DNS_MATCHED="false"
    for ip in "${DNS_IPS[@]}"; do
      if [ "$ip" = "$PRIMARY_IP" ]; then
        DNS_MATCHED="true"
        break
      fi
    done

    if [ "$DNS_MATCHED" = "true" ]; then
      record_pass "DNS name '$DNS_NAME_TO_RESOLVE' resolves to the instance primary private IP"
    else
      record_fail "DNS name '$DNS_NAME_TO_RESOLVE' resolved, but not to primary private IP '$PRIMARY_IP'"
    fi
  fi
else
  record_skip "DNS resolution check (no DNS_NAME_TO_RESOLVE supplied)"
fi

if [ -n "$REQUIRED_SERVICES_CSV" ]; then
  if [ "${#SERVICE_ROWS[@]}" -eq 0 ]; then
    record_fail "No required service results were returned"
  else
    for row in "${SERVICE_ROWS[@]}"; do
      IFS=$'\t' read -r name exists status <<< "$row"
      [ -n "$name" ] || continue

      if [ "${exists,,}" != "true" ]; then
        record_fail "Service '$name' not found"
      elif [ "${status,,}" = "active" ]; then
        record_pass "Service '$name' is active"
      else
        record_fail "Service '$name' status is '$status' not 'active'"
      fi
    done
  fi
else
  record_skip "Required services check (no REQUIRED_SERVICES_CSV supplied)"
fi

echo
echo "Validation summary:"
echo "  Total checks : $TOTAL_CHECKS"
echo "  Passed       : $PASS_COUNT"
echo "  Failed       : $FAIL_COUNT"
echo "  Skipped      : $SKIP_COUNT"

if [ "${#FAILED_CHECKS[@]}" -gt 0 ]; then
  echo "  Failed check details:"
  for item in "${FAILED_CHECKS[@]}"; do
    echo "    - $item"
  done
fi

if [ "${#PASSED_CHECKS[@]}" -gt 0 ]; then
  echo "  Passed check details:"
  for item in "${PASSED_CHECKS[@]}"; do
    echo "    - $item"
  done
fi

if [ "${#SKIPPED_CHECKS[@]}" -gt 0 ]; then
  echo "  Skipped check details:"
  for item in "${SKIPPED_CHECKS[@]}"; do
    echo "    - $item"
  done
fi
echo

if [ "$VALIDATION_FAILURES" -gt 0 ]; then
  if is_true "$FAIL_ON_VALIDATION_ISSUES"; then
    fail "Validation completed with $VALIDATION_FAILURES failure(s)"
  else
    log "Validation completed with $VALIDATION_FAILURES failure(s), but continuing because FAIL_ON_VALIDATION_ISSUES=$FAIL_ON_VALIDATION_ISSUES"
  fi
else
  log "Validation completed successfully"
fi
