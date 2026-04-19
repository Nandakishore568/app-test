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

record_pass() {
  echo "PASS - $1"
}

record_skip() {
  echo "SKIP - $1"
}

record_fail() {
  echo "FAIL - $1"
  VALIDATION_FAILURES=$((VALIDATION_FAILURES + 1))
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

data = json.load(sys.stdin)
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
    "PrivateIpAddress": instance.get("PrivateIpAddress", ""),
    "InstanceType": instance.get("InstanceType", ""),
    "VpcId": instance.get("VpcId", ""),
    "SubnetId": instance.get("SubnetId", ""),
    "AvailabilityZone": instance.get("Placement", {}).get("AvailabilityZone", ""),
    "LaunchTime": instance.get("LaunchTime", "")
}
print(json.dumps(result))
' "${INSTANCE_ID:-}" "${SERVER_NAME:-}")" || fail "instance not found"

TARGET_INSTANCE_ID="$(printf '%s' "$TARGET_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin)["InstanceId"])')"
TARGET_NAME="$(printf '%s' "$TARGET_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin)["Name"])')"
TARGET_STATE="$(printf '%s' "$TARGET_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin)["State"])')"
TARGET_PLATFORM="$(printf '%s' "$TARGET_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin)["PlatformDetails"])')"
TARGET_PRIVATE_IP="$(printf '%s' "$TARGET_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin)["PrivateIpAddress"])')"
TARGET_INSTANCE_TYPE="$(printf '%s' "$TARGET_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin)["InstanceType"])')"
TARGET_VPC_ID="$(printf '%s' "$TARGET_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin)["VpcId"])')"
TARGET_SUBNET_ID="$(printf '%s' "$TARGET_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin)["SubnetId"])')"
TARGET_AZ="$(printf '%s' "$TARGET_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin)["AvailabilityZone"])')"
TARGET_LAUNCH_TIME="$(printf '%s' "$TARGET_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin)["LaunchTime"])')"

log "EC2 instance details:"
echo "  InstanceId       : $TARGET_INSTANCE_ID"
echo "  Name tag         : ${TARGET_NAME:-N/A}"
echo "  State            : ${TARGET_STATE:-N/A}"
echo "  Platform         : ${TARGET_PLATFORM:-N/A}"
echo "  Private IP       : ${TARGET_PRIVATE_IP:-N/A}"
echo "  Instance type    : ${TARGET_INSTANCE_TYPE:-N/A}"
echo "  VPC ID           : ${TARGET_VPC_ID:-N/A}"
echo "  Subnet ID        : ${TARGET_SUBNET_ID:-N/A}"
echo "  AvailabilityZone : ${TARGET_AZ:-N/A}"
echo "  LaunchTime       : ${TARGET_LAUNCH_TIME:-N/A}"

VALIDATION_FAILURES=0

log "Running EC2-level checks..."
if [ "$TARGET_STATE" = "running" ]; then
  record_pass "Instance state is running"
else
  fail "Target instance must be running for SSM validation"
fi

if printf '%s' "$TARGET_PLATFORM" | grep -iq "windows"; then
  record_pass "Platform is Windows"
else
  fail "Target instance is not Windows"
fi

if [ -n "$TARGET_PRIVATE_IP" ]; then
  record_pass "Private IP is populated"
else
  record_fail "Private IP is missing"
fi

compare_exact "InstanceId" "$INSTANCE_ID" "$TARGET_INSTANCE_ID"
compare_case_insensitive "EC2 Name tag" "$SERVER_NAME" "$TARGET_NAME"

log "Building SSM command payload..."
python3 - "$TMP_DIR/ssm-parameters.json" "$REQUIRED_SERVICES_CSV" "$DNS_NAME_TO_RESOLVE" <<'PY'
import json, sys

path = sys.argv[1]
required_services_csv = sys.argv[2]
dns_name = sys.argv[3]

def ps_quote(value: str) -> str:
    return "'" + value.replace("'", "''") + "'"

commands = [
    "$ErrorActionPreference = 'Stop'",
    "$ProgressPreference = 'SilentlyContinue'",
    f"$requiredServicesCsv = {ps_quote(required_services_csv)}",
    f"$dnsName = {ps_quote(dns_name)}",
    "$requiredServices = @()",
    "if ($requiredServicesCsv.Trim()) { $requiredServices = $requiredServicesCsv.Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_ } }",
    "$cs = Get-CimInstance Win32_ComputerSystem",
    "$os = Get-CimInstance Win32_OperatingSystem",
    "$tz = (Get-TimeZone).Id",
    "$services = @()",
    "foreach ($svcName in $requiredServices) {",
    "  $svc = Get-Service -Name $svcName -ErrorAction SilentlyContinue",
    "  if ($null -eq $svc) {",
    "    $services += [pscustomobject]@{ Name = $svcName; Exists = $false; Status = 'NotFound'; DisplayName = '' }",
    "  } else {",
    "    $services += [pscustomobject]@{ Name = $svc.Name; Exists = $true; Status = [string]$svc.Status; DisplayName = $svc.DisplayName }",
    "  }",
    "}",
    "$dnsResolvedIPs = @()",
    "if ($dnsName.Trim()) {",
    "  try {",
    "    $dnsResolvedIPs = Resolve-DnsName -Name $dnsName -ErrorAction Stop | Where-Object { $_.IPAddress } | Select-Object -ExpandProperty IPAddress -Unique",
    "  } catch {",
    "    try {",
    "      $dnsResolvedIPs = [System.Net.Dns]::GetHostAddresses($dnsName) | ForEach-Object { $_.IPAddressToString } | Select-Object -Unique",
    "    } catch {",
    "      $dnsResolvedIPs = @()",
    "    }",
    "  }",
    "}",
    "$lastBoot = ''",
    "try { $lastBoot = ([System.Management.ManagementDateTimeConverter]::ToDateTime($os.LastBootUpTime)).ToString('o') } catch { $lastBoot = '' }",
    "$result = [ordered]@{",
    "  Hostname = $env:COMPUTERNAME;",
    "  Domain = $cs.Domain;",
    "  PartOfDomain = [bool]$cs.PartOfDomain;",
    "  TimeZone = $tz;",
    "  OSName = $os.Caption;",
    "  OSVersion = $os.Version;",
    "  LastBootUpTime = $lastBoot;",
    "  RequiredServices = $services;",
    "  DnsNameQueried = $dnsName;",
    "  DnsResolvedIPs = @($dnsResolvedIPs)",
    "}",
    "$result | ConvertTo-Json -Depth 6 -Compress"
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
data = json.loads(raw)

required = ["Hostname", "Domain", "TimeZone", "RequiredServices", "DnsResolvedIPs"]
for key in required:
    if key not in data:
        print(f"Missing expected key in SSM output: {key}", file=sys.stderr)
        sys.exit(1)

print(json.dumps(data))
')" || fail "SSM output was not valid JSON"

ACTUAL_HOSTNAME="$(printf '%s' "$RESULT_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin)["Hostname"])')"
ACTUAL_DOMAIN="$(printf '%s' "$RESULT_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin)["Domain"])')"
ACTUAL_TIMEZONE="$(printf '%s' "$RESULT_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin)["TimeZone"])')"
ACTUAL_PART_OF_DOMAIN="$(printf '%s' "$RESULT_JSON" | python3 -c 'import json,sys; print(str(json.load(sys.stdin).get("PartOfDomain","")))')"
ACTUAL_OS_NAME="$(printf '%s' "$RESULT_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("OSName",""))')"
ACTUAL_OS_VERSION="$(printf '%s' "$RESULT_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("OSVersion",""))')"
ACTUAL_LAST_BOOT="$(printf '%s' "$RESULT_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("LastBootUpTime",""))')"

log "Collected in-instance details:"
echo "  Hostname         : $ACTUAL_HOSTNAME"
echo "  Domain           : $ACTUAL_DOMAIN"
echo "  PartOfDomain     : $ACTUAL_PART_OF_DOMAIN"
echo "  TimeZone         : $ACTUAL_TIMEZONE"
echo "  OS Name          : ${ACTUAL_OS_NAME:-N/A}"
echo "  OS Version       : ${ACTUAL_OS_VERSION:-N/A}"
echo "  LastBootUpTime   : ${ACTUAL_LAST_BOOT:-N/A}"

echo "  DNS Query        : ${DNS_NAME_TO_RESOLVE:-N/A}"
mapfile -t DNS_IPS < <(printf '%s' "$RESULT_JSON" | python3 -c '
import json, sys
for ip in json.load(sys.stdin).get("DnsResolvedIPs", []):
    print(ip)
')
if [ "${#DNS_IPS[@]}" -eq 0 ]; then
  echo "  DNS Resolved IPs : none"
else
  echo "  DNS Resolved IPs :"
  for ip in "${DNS_IPS[@]}"; do
    echo "    - $ip"
  done
fi

echo "  Required services:"
SERVICE_ROWS="$(printf '%s' "$RESULT_JSON" | python3 -c '
import json, sys
for svc in json.load(sys.stdin).get("RequiredServices", []):
    print("{}|{}|{}|{}".format(
        svc.get("Name", ""),
        svc.get("Exists", False),
        svc.get("Status", ""),
        svc.get("DisplayName", "")
    ))
')"
if [ -z "$SERVICE_ROWS" ]; then
  echo "    - none requested"
else
  while IFS='|' read -r name exists status display_name; do
    [ -n "$name" ] || continue
    echo "    - $name : exists=$exists status=$status"
  done <<< "$SERVICE_ROWS"
fi

log "Running validation checks..."
compare_case_insensitive "Hostname" "$EXPECTED_HOSTNAME" "$ACTUAL_HOSTNAME"
compare_case_insensitive "Domain" "$EXPECTED_DOMAIN" "$ACTUAL_DOMAIN"
compare_exact "TimeZone" "$EXPECTED_TIMEZONE" "$ACTUAL_TIMEZONE"

if [ -n "$DNS_NAME_TO_RESOLVE" ]; then
  if [ "${#DNS_IPS[@]}" -eq 0 ]; then
    record_fail "DNS name '$DNS_NAME_TO_RESOLVE' did not resolve on the instance"
  else
    DNS_MATCHED="false"
    for ip in "${DNS_IPS[@]}"; do
      if [ "$ip" = "$TARGET_PRIVATE_IP" ]; then
        DNS_MATCHED="true"
        break
      fi
    done

    if [ "$DNS_MATCHED" = "true" ]; then
      record_pass "DNS name '$DNS_NAME_TO_RESOLVE' resolves to the instance private IP"
    else
      record_fail "DNS name '$DNS_NAME_TO_RESOLVE' resolved, but not to private IP '$TARGET_PRIVATE_IP'"
    fi
  fi
else
  record_skip "DNS resolution check (no DNS_NAME_TO_RESOLVE supplied)"
fi

if [ -n "$REQUIRED_SERVICES_CSV" ]; then
  while IFS='|' read -r name exists status display_name; do
    [ -n "$name" ] || continue

    if [ "${exists,,}" != "true" ]; then
      record_fail "Service '$name' not found"
    elif [ "${status,,}" = "running" ]; then
      record_pass "Service '$name' is running"
    else
      record_fail "Service '$name' status is '$status' not 'Running'"
    fi
  done <<< "$SERVICE_ROWS"
else
  record_skip "Required services check (no REQUIRED_SERVICES_CSV supplied)"
fi

if [ "$VALIDATION_FAILURES" -gt 0 ]; then
  if is_true "$FAIL_ON_VALIDATION_ISSUES"; then
    fail "Validation completed with $VALIDATION_FAILURES failure(s)"
  else
    log "Validation completed with $VALIDATION_FAILURES failure(s), but continuing because FAIL_ON_VALIDATION_ISSUES=$FAIL_ON_VALIDATION_ISSUES"
  fi
else
  log "Validation completed successfully"
fi
