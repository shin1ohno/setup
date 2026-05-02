# frozen_string_literal: true

#
# AWS Cost Monitor - Monthly cost report → Cognee
#
# Runs on day 3 of every month at 00:00 UTC (09:00 JST), captures the
# previous full month's AWS spend by service / usage type / region,
# scans operational hygiene (unused EIP, unattached EBS, old snapshots),
# pulls Compute Optimizer recommendations, then POSTs a structured
# report to the local Cognee REST API.
#
# Prerequisites:
#   - AWS CLI configured with credentials that have ce:GetCostAndUsage,
#     ce:GetRightsizingRecommendation, ec2:DescribeAddresses,
#     ec2:DescribeVolumes, ec2:DescribeSnapshots,
#     elasticloadbalancing:Describe*, rds:Describe*,
#     compute-optimizer:Get* permissions (the sh1admn profile has these)
#   - Cognee running on localhost:8001
#   - jq + curl
#
# Configuration:
#   ~/.config/aws-cost-monitor/config (created from sample on first run)
#   ~/.config/aws-cost-monitor/cognee-password (mode 0600, contains password)
#

# Linux-only: systemd-user timer not applicable on macOS
return if node[:platform] == "darwin"

setup_root = node[:setup][:root]
user = node[:setup][:user]
home = node[:setup][:home]

# Create directories
directory "#{setup_root}/bin" do
  owner user
  mode "0755"
end

directory "#{home}/.config/aws-cost-monitor" do
  owner user
  mode "0700"
end

directory "#{home}/.local/log" do
  owner user
  mode "0755"
end

# Install report script
file "#{setup_root}/bin/aws-cost-monthly-report" do
  owner user
  mode "0755"
  content <<~'SCRIPT'
    #!/usr/bin/env bash
    #
    # AWS Cost Monthly Report → Cognee
    #
    # Modes:
    #   --dry-run        Output report to stdout, do not POST to Cognee
    #   --month YYYY-MM  Override target month (default: previous full month)
    #
    set -euo pipefail

    # ---- Config ------------------------------------------------------------
    CONFIG_FILE="${HOME}/.config/aws-cost-monitor/config"
    if [[ -f "$CONFIG_FILE" ]]; then
        # shellcheck source=/dev/null
        source "$CONFIG_FILE"
    fi

    : "${AWS_PROFILE:=sh1admn}"
    : "${AWS_REGION:=ap-northeast-1}"
    : "${COGNEE_ENDPOINT:=http://localhost:8001}"
    : "${COGNEE_USER:=default_user@example.com}"
    : "${COGNEE_PASSWORD_FILE:=${HOME}/.config/aws-cost-monitor/cognee-password}"
    : "${COGNEE_DEFAULT_PASSWORD:=default_password}"
    : "${COGNEE_DATASET:=aws_cost_reports}"
    : "${LOG_FILE:=${HOME}/.local/log/aws-cost-monitor.log}"

    export AWS_PROFILE AWS_REGION

    DRY_RUN=0
    TARGET_MONTH=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --dry-run) DRY_RUN=1; shift;;
            --month)   TARGET_MONTH="$2"; shift 2;;
            *)         echo "unknown arg: $1" >&2; exit 2;;
        esac
    done

    # ---- Logging -----------------------------------------------------------
    log() { printf '%s [aws-cost-monitor] %s\n' "$(date -u +%FT%TZ)" "$*" | tee -a "$LOG_FILE" >&2; }
    fail() { log "ERROR: $*"; exit 1; }

    mkdir -p "$(dirname "$LOG_FILE")"

    # ---- Date math ---------------------------------------------------------
    if [[ -z "$TARGET_MONTH" ]]; then
        # Previous full month
        TARGET_MONTH=$(date -u -d "$(date -u +%Y-%m-01) -1 day" +%Y-%m)
    fi
    MONTH_START="${TARGET_MONTH}-01"
    MONTH_END=$(date -u -d "${MONTH_START} +1 month" +%Y-%m-%d)
    PREV_MONTH=$(date -u -d "${MONTH_START} -1 day" +%Y-%m)
    PREV_START="${PREV_MONTH}-01"
    PREV_END="${MONTH_START}"
    SNAPSHOT_CUTOFF=$(date -u -d "180 days ago" +%Y-%m-%dT%H:%M:%S)

    log "Target month: $TARGET_MONTH ($MONTH_START → $MONTH_END)"
    log "Prev month:   $PREV_MONTH ($PREV_START → $PREV_END)"
    log "Profile:      $AWS_PROFILE / $AWS_REGION"
    log "Dry-run:      $DRY_RUN"

    # ---- Helpers -----------------------------------------------------------
    aws_ce() { aws ce "$@" --output json 2>/dev/null || echo '{}'; }
    aws_ec2() { aws ec2 "$@" --region "$AWS_REGION" --output json 2>/dev/null || echo '{}'; }
    aws_rds() { aws rds "$@" --region "$AWS_REGION" --output json 2>/dev/null || echo '{}'; }
    aws_elb() { aws "$@" --region "$AWS_REGION" --output json 2>/dev/null || echo '{}'; }
    aws_co()  { aws compute-optimizer "$@" --region "$AWS_REGION" --output json 2>/dev/null || echo '{}'; }

    round2() { jq -n --arg n "$1" '($n | tonumber) * 100 | round / 100'; }

    # ---- Cost queries ------------------------------------------------------
    log "Querying Cost Explorer..."

    # Q1: target month total + service breakdown
    Q_MONTH=$(aws_ce get-cost-and-usage \
        --time-period "Start=$MONTH_START,End=$MONTH_END" \
        --granularity MONTHLY --metrics UnblendedCost \
        --group-by Type=DIMENSION,Key=SERVICE)

    # Q2: previous month service breakdown (for MoM diff)
    Q_PREV=$(aws_ce get-cost-and-usage \
        --time-period "Start=$PREV_START,End=$PREV_END" \
        --granularity MONTHLY --metrics UnblendedCost \
        --group-by Type=DIMENSION,Key=SERVICE)

    # Q3: target month daily (spike detection)
    Q_DAILY=$(aws_ce get-cost-and-usage \
        --time-period "Start=$MONTH_START,End=$MONTH_END" \
        --granularity DAILY --metrics UnblendedCost)

    # Q4: target month usage type breakdown
    Q_USAGE=$(aws_ce get-cost-and-usage \
        --time-period "Start=$MONTH_START,End=$MONTH_END" \
        --granularity MONTHLY --metrics UnblendedCost \
        --group-by Type=DIMENSION,Key=USAGE_TYPE)

    # Q5: cost forecast — next FULL future calendar month (AWS rejects past Start)
    FORECAST_START=$(date -u -d "$(date -u +%Y-%m-01) +1 month" +%Y-%m-%d)
    FORECAST_END=$(date -u -d "$FORECAST_START +1 month" +%Y-%m-%d)
    Q_FORECAST=$(aws_ce get-cost-forecast \
        --time-period "Start=$FORECAST_START,End=$FORECAST_END" \
        --metric UNBLENDED_COST --granularity MONTHLY)

    # ---- Compute totals ---------------------------------------------------
    TOTAL_MONTH=$(echo "$Q_MONTH" | jq -r '[.ResultsByTime[].Groups[].Metrics.UnblendedCost.Amount | tonumber] | add // 0 | . * 100 | round / 100')
    TOTAL_PREV=$(echo "$Q_PREV" | jq -r '[.ResultsByTime[].Groups[].Metrics.UnblendedCost.Amount | tonumber] | add // 0 | . * 100 | round / 100')
    DIFF_PCT=$(jq -nr --arg m "$TOTAL_MONTH" --arg p "$TOTAL_PREV" \
        'if ($p | tonumber) == 0 then "n/a" else (((($m | tonumber) - ($p | tonumber)) / ($p | tonumber)) * 100 | round | tostring) + "%" end')

    FORECAST_MEAN=$(echo "$Q_FORECAST" | jq -r '.ForecastResultsByTime[0].MeanValue // "n/a"' | awk '{printf "%.2f\n", $1+0}')

    log "Total $TARGET_MONTH: \$$TOTAL_MONTH (vs $PREV_MONTH \$$TOTAL_PREV, $DIFF_PCT)"

    # ---- Operational hygiene ---------------------------------------------
    log "Scanning operational hygiene..."

    UNUSED_EIPS=$(aws_ec2 describe-addresses | jq -r '[.Addresses[] | select(.AssociationId == null)] | length')
    UNATTACHED_EBS=$(aws_ec2 describe-volumes --filters Name=status,Values=available | jq -r '.Volumes | length')
    UNATTACHED_EBS_GB=$(aws_ec2 describe-volumes --filters Name=status,Values=available | jq -r '[.Volumes[].Size] | add // 0')
    OLD_SNAPSHOTS=$(aws_ec2 describe-snapshots --owner-ids self | jq --arg cutoff "$SNAPSHOT_CUTOFF" -r '[.Snapshots[] | select(.StartTime < $cutoff)] | length')
    OLD_SNAPSHOTS_GB=$(aws_ec2 describe-snapshots --owner-ids self | jq --arg cutoff "$SNAPSHOT_CUTOFF" -r '[.Snapshots[] | select(.StartTime < $cutoff) | .VolumeSize] | add // 0')

    LBS=$(aws_elb elbv2 describe-load-balancers | jq -r '[.LoadBalancers[].LoadBalancerName] | join(", ")')
    LBS_CLASSIC=$(aws_elb elb describe-load-balancers | jq -r '[.LoadBalancerDescriptions[].LoadBalancerName] | join(", ")')

    # Compute Optimizer recommendations
    CO_STATUS=$(aws_co get-enrollment-status | jq -r '.status // "unknown"')
    if [[ "$CO_STATUS" == "Active" ]]; then
        EC2_RECS=$(aws_co get-ec2-instance-recommendations | jq -r '
            [.instanceRecommendations[] | select(.finding != "OPTIMIZED")] |
            map("- \(.instanceArn | split("/")[-1]): \(.currentInstanceType) → \(.recommendationOptions[0].instanceType // "?") (~\\$\(.recommendationOptions[0].estimatedMonthlySavings.value // 0 | . * 100 | round / 100)/mo savings)") |
            if length == 0 then "All EC2 instances OPTIMIZED" else join("\n") end')
    else
        EC2_RECS="Compute Optimizer enrollment status: $CO_STATUS"
    fi

    # ---- Build report -----------------------------------------------------
    log "Building report markdown..."

    TOP_SERVICES=$(echo "$Q_MONTH" "$Q_PREV" | jq -s -r --arg total "$TOTAL_MONTH" '
        (.[0].ResultsByTime[0].Groups // []) as $cur |
        (.[1].ResultsByTime[0].Groups // []) as $pre |
        ($pre | map({(.Keys[0]): (.Metrics.UnblendedCost.Amount | tonumber)}) | add // {}) as $premap |
        $cur | map({
            svc: .Keys[0],
            amt: (.Metrics.UnblendedCost.Amount | tonumber),
            prev: ($premap[.Keys[0]] // 0)
        }) | sort_by(-.amt) | .[0:10] |
        to_entries |
        map("\(.key + 1). **\(.value.svc)**: $\(.value.amt | . * 100 | round / 100) (\((.value.amt / ($total | tonumber) * 100) | round)%) — vs prev $\(.value.prev | . * 100 | round / 100) (Δ\(if .value.prev == 0 then "new" else (((.value.amt - .value.prev) / .value.prev * 100) | round | tostring) + "%" end))") |
        join("\n")')

    DAILY_ANOMALIES=$(echo "$Q_DAILY" | jq -r '
        [.ResultsByTime[] | {date: .TimePeriod.Start, amt: (.Total.UnblendedCost.Amount | tonumber)}] as $days |
        ($days | map(.amt) | add / length) as $mean |
        ($days | map((.amt - $mean) | . * .) | add / length | sqrt) as $sd |
        $days | map(select(.amt > $mean + 2 * $sd)) |
        if length == 0 then "(none)" else
            map("- \(.date): $\(.amt | . * 100 | round / 100) (mean $\($mean | . * 100 | round / 100), σ $\($sd | . * 100 | round / 100))") | join("\n")
        end')

    MOM_ANOMALIES=$(echo "$Q_MONTH" "$Q_PREV" | jq -s -r '
        (.[0].ResultsByTime[0].Groups // []) as $cur |
        (.[1].ResultsByTime[0].Groups // []) as $pre |
        ($pre | map({(.Keys[0]): (.Metrics.UnblendedCost.Amount | tonumber)}) | add // {}) as $premap |
        $cur | map({
            svc: .Keys[0],
            cur: (.Metrics.UnblendedCost.Amount | tonumber),
            pre: ($premap[.Keys[0]] // 0)
        }) | map(select((.cur > 0.5 or .pre > 0.5) and (
            (.pre == 0 and .cur > 1) or
            (.pre > 0 and ((.cur - .pre) / .pre | if . < 0 then -. else . end) > 0.5)
        ))) |
        if length == 0 then "(none)" else
            map("- **\(.svc)**: was $\(.pre | . * 100 | round / 100), now $\(.cur | . * 100 | round / 100) (Δ\(if .pre == 0 then "new" else (((.cur - .pre) / .pre * 100) | round | tostring) + "%" end))") | join("\n")
        end')

    TOP_USAGE=$(echo "$Q_USAGE" | jq -r '
        [.ResultsByTime[].Groups[]] | sort_by(-(.Metrics.UnblendedCost.Amount | tonumber)) | .[0:15] |
        map("- \(.Keys[0]): $\(.Metrics.UnblendedCost.Amount | tonumber | . * 100 | round / 100)") | join("\n")')

    REPORT_FILE=$(mktemp -t "aws_cost_report_${TARGET_MONTH//-/_}.XXXXXX")
    cat > "$REPORT_FILE" <<EOF
## Analysis: AWS Cost Report $TARGET_MONTH
Account: $(aws sts get-caller-identity --query Account --output text 2>/dev/null || echo unknown)
Region: $AWS_REGION
Period: $MONTH_START → $MONTH_END
Total: \$$TOTAL_MONTH (vs $PREV_MONTH \$$TOTAL_PREV, $DIFF_PCT)
Forecast next full month ($FORECAST_START → $FORECAST_END): \$$FORECAST_MEAN

### Top services
$TOP_SERVICES

### Top usage types
$TOP_USAGE

### Daily anomalies (>2σ from mean)
$DAILY_ANOMALIES

### MoM anomalies (>50% absolute change, services >\$0.50)
$MOM_ANOMALIES

### Action recommendations
**EC2 rightsizing (Compute Optimizer):**
$EC2_RECS

### Operational hygiene
- Unused EIPs: $UNUSED_EIPS
- Unattached EBS volumes: $UNATTACHED_EBS (total ${UNATTACHED_EBS_GB}GB)
- Snapshots > 180 days old: $OLD_SNAPSHOTS (total ${OLD_SNAPSHOTS_GB}GB, est. \$$(round2 "$(jq -n --arg gb "$OLD_SNAPSHOTS_GB" '($gb | tonumber) * 0.05')")/mo)
- Active load balancers: ${LBS:-(none)} ${LBS_CLASSIC:+| classic: $LBS_CLASSIC}

### Source
Generated by aws-cost-monitor cookbook on $(hostname -s) at $(date -u +%FT%TZ).
Profile: $AWS_PROFILE | Region: $AWS_REGION
EOF

    if [[ "$DRY_RUN" -eq 1 ]]; then
        log "Dry-run output:"
        cat "$REPORT_FILE"
        rm -f "$REPORT_FILE"
        exit 0
    fi

    # ---- POST to Cognee ---------------------------------------------------
    log "Authenticating to Cognee at $COGNEE_ENDPOINT..."

    if [[ -f "$COGNEE_PASSWORD_FILE" ]]; then
        COGNEE_PASSWORD=$(cat "$COGNEE_PASSWORD_FILE")
    else
        COGNEE_PASSWORD="$COGNEE_DEFAULT_PASSWORD"
    fi

    TOKEN=$(curl -fsS -X POST "${COGNEE_ENDPOINT}/api/v1/auth/login" \
        --data-urlencode "username=${COGNEE_USER}" \
        --data-urlencode "password=${COGNEE_PASSWORD}" \
        | jq -r '.access_token // empty') || fail "Cognee auth failed"

    [[ -n "$TOKEN" ]] || fail "Cognee auth returned empty token"

    # Use deterministic filename so re-runs overwrite (per Cognee data_id rule)
    UPLOAD_NAME="aws_cost_report_${TARGET_MONTH//-/_}.txt"
    cp "$REPORT_FILE" "/tmp/$UPLOAD_NAME"

    log "Uploading report ($(wc -c < "/tmp/$UPLOAD_NAME") bytes) to dataset $COGNEE_DATASET..."
    ADD_RESULT=$(curl -fsS -X POST "${COGNEE_ENDPOINT}/api/v1/add" \
        -H "Authorization: Bearer $TOKEN" \
        -F "data=@/tmp/$UPLOAD_NAME" \
        -F "datasetName=${COGNEE_DATASET}") || fail "Cognee add failed"

    log "Add response: $ADD_RESULT"

    log "Triggering cognify on dataset $COGNEE_DATASET (fire-and-forget; LLM extraction is async)..."
    # cognify can take several minutes for LLM-based knowledge graph extraction.
    # The /add call above already persisted the data; cognify only enriches it.
    # We give the call up to 60s, then proceed regardless — failure here is non-fatal.
    if COGNIFY_RESULT=$(curl -fsS --max-time 60 -X POST "${COGNEE_ENDPOINT}/api/v1/cognify" \
        -H "Authorization: Bearer $TOKEN" \
        -H "Content-Type: application/json" \
        -d "{\"datasets\": [\"${COGNEE_DATASET}\"]}" 2>&1); then
        log "Cognify response: $COGNIFY_RESULT"
    else
        log "Cognify call timed out or failed (non-fatal — data is persisted; graph extraction may complete in background)"
    fi

    # Cleanup
    rm -f "$REPORT_FILE" "/tmp/$UPLOAD_NAME"

    log "Report uploaded successfully (data_id persisted via /api/v1/add). Verify with: search Cognee for 'AWS Cost Report $TARGET_MONTH'"
  SCRIPT
end

# Sample config (user copies to 'config' and customizes)
file "#{home}/.config/aws-cost-monitor/config.sample" do
  owner user
  mode "0600"
  content <<~CONFIG
    # AWS Cost Monitor configuration
    # Copy to ~/.config/aws-cost-monitor/config and edit as needed.

    # AWS profile + region (used by aws CLI)
    AWS_PROFILE=sh1admn
    AWS_REGION=ap-northeast-1

    # Cognee REST endpoint (assumes localhost on the same host)
    COGNEE_ENDPOINT=http://localhost:8001
    COGNEE_USER=default_user@example.com
    COGNEE_PASSWORD_FILE=$HOME/.config/aws-cost-monitor/cognee-password
    COGNEE_DATASET=aws_cost_reports

    # Log file (also writes to journal via systemd)
    LOG_FILE=$HOME/.local/log/aws-cost-monitor.log
  CONFIG
end

# systemd user service + timer
directory "#{home}/.config/systemd/user" do
  owner user
  mode "0755"
end

file "#{home}/.config/systemd/user/aws-cost-monthly.service" do
  owner user
  mode "0644"
  content <<~SERVICE
    [Unit]
    Description=AWS Monthly Cost Report → Cognee
    After=network-online.target
    Wants=network-online.target

    [Service]
    Type=oneshot
    ExecStart=#{setup_root}/bin/aws-cost-monthly-report
    StandardOutput=journal
    StandardError=journal

    NoNewPrivileges=yes
    PrivateTmp=yes

    [Install]
    WantedBy=default.target
  SERVICE
end

file "#{home}/.config/systemd/user/aws-cost-monthly.timer" do
  owner user
  mode "0644"
  content <<~TIMER
    [Unit]
    Description=Trigger AWS monthly cost report on day 3 at 00:00 UTC

    [Timer]
    # Day 3 of every month at 00:00 UTC = 09:00 JST.
    # AWS billing finalizes 1-3 days after month end; day 3 is safe.
    OnCalendar=*-*-03 00:00:00 UTC
    # Catch missed runs if box was off at trigger time
    Persistent=true
    Unit=aws-cost-monthly.service

    [Install]
    WantedBy=timers.target
  TIMER
end

# README — user must run systemctl --user enable themselves (mitamae has no D-Bus session)
file "#{setup_root}/bin/aws-cost-monthly-report.README.md" do
  owner user
  mode "0644"
  content <<~README
    # AWS Cost Monitor

    Monthly AWS cost report → Cognee, structured per the
    "Analysis" format in `~/.claude/docs/knowledge-persistence.md`.

    ## Setup

    1. Configure Cognee credentials (only if non-default):
       ```bash
       cp ~/.config/aws-cost-monitor/config.sample ~/.config/aws-cost-monitor/config
       echo -n 'your_cognee_password' > ~/.config/aws-cost-monitor/cognee-password
       chmod 600 ~/.config/aws-cost-monitor/cognee-password
       ```

    2. Test in dry-run mode:
       ```bash
       #{setup_root}/bin/aws-cost-monthly-report --dry-run
       ```

    3. Run end-to-end once (uploads to Cognee):
       ```bash
       #{setup_root}/bin/aws-cost-monthly-report
       ```

    4. Enable monthly schedule:
       ```bash
       systemctl --user daemon-reload
       systemctl --user enable --now aws-cost-monthly.timer
       systemctl --user list-timers aws-cost-monthly.timer
       ```

    ## Override target month

    ```bash
    #{setup_root}/bin/aws-cost-monthly-report --month 2026-04
    ```

    ## Logs

    - File: `~/.local/log/aws-cost-monitor.log`
    - journald: `journalctl --user -u aws-cost-monthly.service`
  README
end
