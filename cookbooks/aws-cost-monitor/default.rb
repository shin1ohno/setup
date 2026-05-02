# frozen_string_literal: true

#
# AWS Cost Monitor - Daily cost snapshot → Cognee
#
# Runs every day at 06:00 JST (21:00 UTC previous day), captures yesterday's
# spend, MTD total, prev-month comparison, and current/next-month forecasts.
# Saves a structured snapshot to local Cognee (one entry per calendar date).
#
# A separate claude.ai RemoteTrigger reads these snapshots daily at 09:00 JST
# and generates "AWS Cost Proposal" entries with improvement suggestions.
#
# Prerequisites:
#   - AWS CLI configured with ce:Get*, ec2:Describe*, rds:Describe*,
#     elasticloadbalancing:Describe*, compute-optimizer:Get* permissions
#     (the sh1admn profile has these)
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

# Install snapshot script
file "#{setup_root}/bin/aws-cost-snapshot" do
  owner user
  mode "0755"
  content <<~'SCRIPT'
    #!/usr/bin/env bash
    #
    # AWS Cost Daily Snapshot → Cognee
    #
    # Modes:
    #   --dry-run        Output snapshot to stdout, do not POST to Cognee
    #   --date YYYY-MM-DD  Override target date (default: today)
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
    TARGET_DATE=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --dry-run) DRY_RUN=1; shift;;
            --date)    TARGET_DATE="$2"; shift 2;;
            *)         echo "unknown arg: $1" >&2; exit 2;;
        esac
    done

    # ---- Logging -----------------------------------------------------------
    log() { printf '%s [aws-cost-snapshot] %s\n' "$(date -u +%FT%TZ)" "$*" | tee -a "$LOG_FILE" >&2; }
    fail() { log "ERROR: $*"; exit 1; }

    mkdir -p "$(dirname "$LOG_FILE")"

    # ---- Date math ---------------------------------------------------------
    [[ -z "$TARGET_DATE" ]] && TARGET_DATE=$(date -u +%Y-%m-%d)

    YESTERDAY=$(date -u -d "${TARGET_DATE} -1 day" +%Y-%m-%d)
    MONTH_START=$(date -u -d "${TARGET_DATE}" +%Y-%m-01)
    MONTH_END=$(date -u -d "${MONTH_START} +1 month" +%Y-%m-%d)
    PREV_MONTH=$(date -u -d "${MONTH_START} -1 day" +%Y-%m)
    PREV_MONTH_START="${PREV_MONTH}-01"
    PREV_MONTH_END="${MONTH_START}"
    NEXT_MONTH_START="${MONTH_END}"
    NEXT_MONTH_END=$(date -u -d "${NEXT_MONTH_START} +1 month" +%Y-%m-%d)
    SNAPSHOT_CUTOFF=$(date -u -d "180 days ago" +%Y-%m-%dT%H:%M:%S)

    # CE expects exclusive end. Yesterday's data: Start=YESTERDAY, End=TARGET_DATE.
    log "Target date:        $TARGET_DATE"
    log "Yesterday:          $YESTERDAY"
    log "MTD window:         $MONTH_START → $TARGET_DATE"
    log "Previous month:     $PREV_MONTH_START → $PREV_MONTH_END"
    log "Forecast remaining: $TARGET_DATE → $MONTH_END"
    log "Forecast next month:$NEXT_MONTH_START → $NEXT_MONTH_END"
    log "Profile:            $AWS_PROFILE / $AWS_REGION"
    log "Dry-run:            $DRY_RUN"

    # ---- Helpers -----------------------------------------------------------
    aws_ce() { aws ce "$@" --output json 2>/dev/null || echo '{}'; }
    aws_ec2() { aws ec2 "$@" --region "$AWS_REGION" --output json 2>/dev/null || echo '{}'; }
    aws_elb() { aws "$@" --region "$AWS_REGION" --output json 2>/dev/null || echo '{}'; }
    aws_co()  { aws compute-optimizer "$@" --region "$AWS_REGION" --output json 2>/dev/null || echo '{}'; }

    # ---- Cost queries ------------------------------------------------------
    log "Querying Cost Explorer..."

    # Q1: yesterday's spend by service
    Q_YESTERDAY=$(aws_ce get-cost-and-usage \
        --time-period "Start=$YESTERDAY,End=$TARGET_DATE" \
        --granularity DAILY --metrics UnblendedCost \
        --group-by Type=DIMENSION,Key=SERVICE)

    # Q2: MTD by service (current month, $MONTH_START → $TARGET_DATE)
    if [[ "$TARGET_DATE" != "$MONTH_START" ]]; then
        Q_MTD=$(aws_ce get-cost-and-usage \
            --time-period "Start=$MONTH_START,End=$TARGET_DATE" \
            --granularity MONTHLY --metrics UnblendedCost \
            --group-by Type=DIMENSION,Key=SERVICE)
    else
        Q_MTD='{"ResultsByTime":[{"Groups":[]}]}'
    fi

    # Q3: previous full month by service (for MoM compare)
    Q_PREV=$(aws_ce get-cost-and-usage \
        --time-period "Start=$PREV_MONTH_START,End=$PREV_MONTH_END" \
        --granularity MONTHLY --metrics UnblendedCost \
        --group-by Type=DIMENSION,Key=SERVICE)

    # Q4: daily series (full current month so far) for trend / spike detection
    if [[ "$TARGET_DATE" != "$MONTH_START" ]]; then
        Q_DAILY=$(aws_ce get-cost-and-usage \
            --time-period "Start=$MONTH_START,End=$TARGET_DATE" \
            --granularity DAILY --metrics UnblendedCost)
    else
        Q_DAILY='{"ResultsByTime":[]}'
    fi

    # Q5a: forecast remaining days of current month
    Q_FORECAST_THIS=$(aws_ce get-cost-forecast \
        --time-period "Start=$TARGET_DATE,End=$MONTH_END" \
        --metric UNBLENDED_COST --granularity MONTHLY)

    # Q5b: forecast next full month
    Q_FORECAST_NEXT=$(aws_ce get-cost-forecast \
        --time-period "Start=$NEXT_MONTH_START,End=$NEXT_MONTH_END" \
        --metric UNBLENDED_COST --granularity MONTHLY)

    # ---- Compute totals ---------------------------------------------------
    YESTERDAY_TOTAL=$(echo "$Q_YESTERDAY" | jq -r '[.ResultsByTime[].Groups[].Metrics.UnblendedCost.Amount | tonumber] | add // 0 | . * 100 | round / 100')
    MTD_TOTAL=$(echo "$Q_MTD" | jq -r '[.ResultsByTime[].Groups[].Metrics.UnblendedCost.Amount | tonumber] | add // 0 | . * 100 | round / 100')
    PREV_TOTAL=$(echo "$Q_PREV" | jq -r '[.ResultsByTime[].Groups[].Metrics.UnblendedCost.Amount | tonumber] | add // 0 | . * 100 | round / 100')

    FORECAST_REMAINING=$(echo "$Q_FORECAST_THIS" | jq -r '.ForecastResultsByTime[0].MeanValue // 0' | awk '{printf "%.2f\n", $1+0}')
    FORECAST_NEXT=$(echo "$Q_FORECAST_NEXT" | jq -r '.ForecastResultsByTime[0].MeanValue // 0' | awk '{printf "%.2f\n", $1+0}')
    FORECAST_EOM=$(awk -v m="$MTD_TOTAL" -v r="$FORECAST_REMAINING" 'BEGIN{printf "%.2f\n", m+r}')

    log "Yesterday: \$$YESTERDAY_TOTAL"
    log "MTD: \$$MTD_TOTAL (prev month total \$$PREV_TOTAL)"
    log "Forecast EOM: \$$FORECAST_EOM (MTD \$$MTD_TOTAL + remaining \$$FORECAST_REMAINING)"
    log "Forecast next month: \$$FORECAST_NEXT"

    # ---- Operational hygiene ---------------------------------------------
    log "Scanning operational hygiene..."

    UNUSED_EIPS=$(aws_ec2 describe-addresses | jq -r '[.Addresses[] | select(.AssociationId == null)] | length')
    UNATTACHED_EBS=$(aws_ec2 describe-volumes --filters Name=status,Values=available | jq -r '.Volumes | length')
    UNATTACHED_EBS_GB=$(aws_ec2 describe-volumes --filters Name=status,Values=available | jq -r '[.Volumes[].Size] | add // 0')
    OLD_SNAPSHOTS=$(aws_ec2 describe-snapshots --owner-ids self | jq --arg cutoff "$SNAPSHOT_CUTOFF" -r '[.Snapshots[] | select(.StartTime < $cutoff)] | length')
    OLD_SNAPSHOTS_GB=$(aws_ec2 describe-snapshots --owner-ids self | jq --arg cutoff "$SNAPSHOT_CUTOFF" -r '[.Snapshots[] | select(.StartTime < $cutoff) | .VolumeSize] | add // 0')

    LBS=$(aws_elb elbv2 describe-load-balancers | jq -r '[.LoadBalancers[].LoadBalancerName] | join(", ")')
    LBS_CLASSIC=$(aws_elb elb describe-load-balancers | jq -r '[.LoadBalancerDescriptions[].LoadBalancerName] | join(", ")')

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
    log "Building snapshot markdown..."

    YDAY_TOP=$(echo "$Q_YESTERDAY" | jq -r '
        .ResultsByTime[0].Groups // [] | sort_by(-(.Metrics.UnblendedCost.Amount | tonumber)) | .[0:5] |
        if length == 0 then "(no spend yesterday)" else
            map("- \(.Keys[0]): $\(.Metrics.UnblendedCost.Amount | tonumber | . * 100 | round / 100)") | join("\n")
        end')

    MTD_TOP=$(echo "$Q_MTD" "$Q_PREV" | jq -s -r --arg total "$MTD_TOTAL" --arg ptotal "$PREV_TOTAL" '
        ((.[0].ResultsByTime[0].Groups // [])) as $cur |
        ((.[1].ResultsByTime[0].Groups // [])) as $pre |
        ($pre | map({(.Keys[0]): (.Metrics.UnblendedCost.Amount | tonumber)}) | add // {}) as $premap |
        $cur | map({
            svc: .Keys[0],
            amt: (.Metrics.UnblendedCost.Amount | tonumber),
            prev: ($premap[.Keys[0]] // 0)
        }) | sort_by(-.amt) | .[0:10] |
        if length == 0 then "(no MTD spend yet)" else
            to_entries |
            map("\(.key + 1). **\(.value.svc)**: $\(.value.amt | . * 100 | round / 100)\(if ($total | tonumber) > 0 then " (\((.value.amt / ($total | tonumber) * 100) | round)%)" else "" end) — prev-month $\(.value.prev | . * 100 | round / 100)") |
            join("\n")
        end')

    DAILY_TREND=$(echo "$Q_DAILY" | jq -r '
        .ResultsByTime // [] |
        if length == 0 then "(insufficient data)" else
            map("- \(.TimePeriod.Start): $\(.Total.UnblendedCost.Amount | tonumber | . * 100 | round / 100)") | join("\n")
        end')

    DAILY_ANOMALY=$(echo "$Q_DAILY" | jq -r '
        [.ResultsByTime[] | {date: .TimePeriod.Start, amt: (.Total.UnblendedCost.Amount | tonumber)}] as $days |
        if ($days | length) < 3 then "(need ≥3 days)" else
            ($days | map(.amt) | add / length) as $mean |
            ($days | map((.amt - $mean) | . * .) | add / length | sqrt) as $sd |
            $days | map(select(.amt > $mean + 2 * $sd)) |
            if length == 0 then "(none)" else
                map("- \(.date): $\(.amt | . * 100 | round / 100) (mean $\($mean | . * 100 | round / 100), σ $\($sd | . * 100 | round / 100))") | join("\n")
            end
        end')

    DAYS_ELAPSED=$(( $(date -u -d "$TARGET_DATE" +%d) - 1 ))
    [[ "$DAYS_ELAPSED" -lt 1 ]] && DAYS_ELAPSED=1
    MOM_ANOMALY=$(echo "$Q_MTD" "$Q_PREV" | jq -s -r --argjson days "$DAYS_ELAPSED" '
        ((.[0].ResultsByTime[0].Groups // [])) as $cur |
        ((.[1].ResultsByTime[0].Groups // [])) as $pre |
        ($pre | map({(.Keys[0]): (.Metrics.UnblendedCost.Amount | tonumber)}) | add // {}) as $premap |
        # Compare MTD to (prev_total * days_elapsed / 30) as a pace projection.
        $cur | map({
            svc: .Keys[0],
            cur: (.Metrics.UnblendedCost.Amount | tonumber),
            pre_proj: (($premap[.Keys[0]] // 0) * $days / 30)
        }) | map(select(.cur > 1 or .pre_proj > 1)) |
        map(select(
            (.pre_proj < 0.1 and .cur > 1) or
            (.pre_proj >= 0.1 and ((.cur - .pre_proj) / .pre_proj | if . < 0 then -. else . end) > 0.5)
        )) |
        if length == 0 then "(no >50% deviations)" else
            map("- **\(.svc)**: MTD $\(.cur | . * 100 | round / 100), prev-month projected-to-date $\(.pre_proj | . * 100 | round / 100)") | join("\n")
        end')

    REPORT_FILE=$(mktemp -t "aws_cost_snapshot_${TARGET_DATE//-/_}.XXXXXX")
    cat > "$REPORT_FILE" <<EOF
## Analysis: AWS Cost Snapshot $TARGET_DATE
Account: $(aws sts get-caller-identity --query Account --output text 2>/dev/null || echo unknown)
Region: $AWS_REGION
Period: yesterday ($YESTERDAY) + MTD ($MONTH_START → $TARGET_DATE)

### Headline numbers
- Yesterday total: \$$YESTERDAY_TOTAL
- MTD total: \$$MTD_TOTAL
- Previous month full total ($PREV_MONTH): \$$PREV_TOTAL
- Forecast remaining ($TARGET_DATE → $MONTH_END): \$$FORECAST_REMAINING
- **Forecast EOM**: \$$FORECAST_EOM
- Forecast next month: \$$FORECAST_NEXT

### Yesterday — top 5 services
$YDAY_TOP

### MTD — top 10 services (vs previous full month)
$MTD_TOP

### Daily trend (current month so far)
$DAILY_TREND

### Daily spike anomalies (>2σ from MTD mean)
$DAILY_ANOMALY

### MoM anomalies (services >50% off prev-month projected-to-date pace)
$MOM_ANOMALY

### Action recommendations
**EC2 rightsizing (Compute Optimizer):**
$EC2_RECS

### Operational hygiene
- Unused EIPs: $UNUSED_EIPS
- Unattached EBS volumes: $UNATTACHED_EBS (total ${UNATTACHED_EBS_GB}GB)
- Snapshots > 180 days old: $OLD_SNAPSHOTS (total ${OLD_SNAPSHOTS_GB}GB, est. \$$(awk -v gb="$OLD_SNAPSHOTS_GB" 'BEGIN{printf "%.2f\n", gb*0.05}')/mo)
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

    UPLOAD_NAME="aws_cost_snapshot_${TARGET_DATE//-/_}.txt"
    cp "$REPORT_FILE" "/tmp/$UPLOAD_NAME"

    log "Uploading snapshot ($(wc -c < "/tmp/$UPLOAD_NAME") bytes) to dataset $COGNEE_DATASET..."
    ADD_RESULT=$(curl -fsS -X POST "${COGNEE_ENDPOINT}/api/v1/add" \
        -H "Authorization: Bearer $TOKEN" \
        -F "data=@/tmp/$UPLOAD_NAME" \
        -F "datasetName=${COGNEE_DATASET}") || fail "Cognee add failed"

    log "Add response: $ADD_RESULT"

    log "Triggering cognify on dataset $COGNEE_DATASET (fire-and-forget; LLM extraction is async)..."
    if COGNIFY_RESULT=$(curl -fsS --max-time 60 -X POST "${COGNEE_ENDPOINT}/api/v1/cognify" \
        -H "Authorization: Bearer $TOKEN" \
        -H "Content-Type: application/json" \
        -d "{\"datasets\": [\"${COGNEE_DATASET}\"]}" 2>&1); then
        log "Cognify response: $COGNIFY_RESULT"
    else
        log "Cognify call timed out or failed (non-fatal — data is persisted; graph extraction may complete in background)"
    fi

    rm -f "$REPORT_FILE" "/tmp/$UPLOAD_NAME"

    log "Snapshot uploaded successfully (data_id persisted via /api/v1/add). Verify with: search Cognee for 'AWS Cost Snapshot $TARGET_DATE'"
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

file "#{home}/.config/systemd/user/aws-cost-snapshot.service" do
  owner user
  mode "0644"
  content <<~SERVICE
    [Unit]
    Description=AWS Daily Cost Snapshot → Cognee
    After=network-online.target
    Wants=network-online.target

    [Service]
    Type=oneshot
    ExecStart=#{setup_root}/bin/aws-cost-snapshot
    StandardOutput=journal
    StandardError=journal

    NoNewPrivileges=yes
    PrivateTmp=yes

    [Install]
    WantedBy=default.target
  SERVICE
end

file "#{home}/.config/systemd/user/aws-cost-snapshot.timer" do
  owner user
  mode "0644"
  content <<~TIMER
    [Unit]
    Description=Trigger AWS daily cost snapshot at 06:00 JST (21:00 UTC prev day)

    [Timer]
    # 06:00 JST = 21:00 UTC. systemd-user services use UTC, so:
    OnCalendar=*-*-* 21:00:00 UTC
    # Catch missed runs if box was off at trigger time
    Persistent=true
    # Spread load if multiple timers fire at the same minute
    RandomizedDelaySec=300
    Unit=aws-cost-snapshot.service

    [Install]
    WantedBy=timers.target
  TIMER
end

# README — user must run systemctl --user enable themselves (mitamae has no D-Bus session)
file "#{setup_root}/bin/aws-cost-snapshot.README.md" do
  owner user
  mode "0644"
  content <<~README
    # AWS Cost Monitor

    Daily AWS cost snapshot → Cognee. Captures yesterday's spend, MTD,
    prev-month total, and current/next-month forecasts. A claude.ai
    RemoteTrigger reads these snapshots and generates daily improvement
    proposals.

    ## Setup

    1. Configure Cognee credentials (only if non-default):
       ```bash
       cp ~/.config/aws-cost-monitor/config.sample ~/.config/aws-cost-monitor/config
       echo -n 'your_cognee_password' > ~/.config/aws-cost-monitor/cognee-password
       chmod 600 ~/.config/aws-cost-monitor/cognee-password
       ```

    2. Test in dry-run mode:
       ```bash
       #{setup_root}/bin/aws-cost-snapshot --dry-run
       ```

    3. Run end-to-end once (uploads to Cognee):
       ```bash
       #{setup_root}/bin/aws-cost-snapshot
       ```

    4. Enable daily schedule:
       ```bash
       systemctl --user daemon-reload
       systemctl --user enable --now aws-cost-snapshot.timer
       systemctl --user list-timers aws-cost-snapshot.timer
       ```

    ## Override target date

    ```bash
    #{setup_root}/bin/aws-cost-snapshot --date 2026-04-30
    ```

    ## Logs

    - File: `~/.local/log/aws-cost-monitor.log`
    - journald: `journalctl --user -u aws-cost-snapshot.service`
  README
end
