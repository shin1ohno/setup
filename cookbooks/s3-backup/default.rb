# frozen_string_literal: true

#
# S3 Backup - Daily encrypted backup of sensitive files to S3
#
# Prerequisites:
#   - AWS CLI configured with appropriate credentials
#   - GPG key for encryption
#   - S3 bucket created with appropriate permissions
#
# Configuration:
#   Create ~/.config/s3-backup/config with:
#     S3_BUCKET=your-backup-bucket
#     GPG_RECIPIENT=your-gpg-key-id
#

setup_root = node[:setup][:root]
user = node[:setup][:user]

# Create directories
directory "#{setup_root}/bin" do
  owner user
  mode "0755"
end

directory "#{ENV['HOME']}/.config/s3-backup" do
  owner user
  mode "0700"
end

directory "#{ENV['HOME']}/.local/log" do
  owner user
  mode "0755"
end

# Install backup script
file "#{setup_root}/bin/s3-backup" do
  owner user
  mode "0755"
  content <<~'SCRIPT'
    #!/usr/bin/env bash
    #
    # S3 Backup Script - Securely backup sensitive files to S3
    #
    # Features:
    # - GPG encryption before upload
    # - Secure temp file handling
    # - Automatic rotation of old backups
    # - Error handling and logging
    #

    set -euo pipefail

    # Configuration (override via environment or config file)
    CONFIG_FILE="${HOME}/.config/s3-backup/config"
    if [[ -f "$CONFIG_FILE" ]]; then
        # shellcheck source=/dev/null
        source "$CONFIG_FILE"
    fi

    S3_BUCKET="${S3_BUCKET:-}"
    S3_PREFIX="${S3_PREFIX:-backups/$(hostname)}"
    GPG_RECIPIENT="${GPG_RECIPIENT:-}"
    RETENTION_DAYS="${RETENTION_DAYS:-30}"
    LOG_FILE="${LOG_FILE:-${HOME}/.local/log/s3-backup.log}"

    # Backup targets (secrets and credentials only)
    # Excluded (managed elsewhere):
    #   ~/.gitconfig           -> cookbooks/git/
    #   ~/.config/mise         -> cookbooks/mise/
    #   ~/.config/nvim         -> github.com/shin1ohno/astro
    #   ~/.setup_shin1ohno     -> this repository
    #   ~/.claude/CLAUDE.md    -> cookbooks/claude-code/
    #   ~/.claude/settings.json-> cookbooks/claude-code/
    #   ~/.claude-agents.json  -> cookbooks/claude-code/
    BACKUP_PATHS=(
        "${HOME}/.ssh"
        "${HOME}/.gnupg"
        "${HOME}/.aws"
        "${HOME}/.config/gcloud"
        "${HOME}/.env"
        "${HOME}/.dotenv"
        "${HOME}/.boto"
        "${HOME}/.claude/.credentials.json"
        "${HOME}/.claude.json"
        "${HOME}/.config/gh"
    )

    # Ensure log directory exists
    mkdir -p "$(dirname "$LOG_FILE")"

    log() {
        local level="$1"
        shift
        local message="$*"
        local timestamp
        timestamp=$(date '+%Y-%m-%d %H:%M:%S')
        echo "[$timestamp] [$level] $message" | tee -a "$LOG_FILE"
    }

    log_info() { log "INFO" "$@"; }
    log_warn() { log "WARN" "$@"; }
    log_error() { log "ERROR" "$@"; }

    die() {
        log_error "$@"
        exit 1
    }

    check_requirements() {
        local missing=()

        command -v aws &>/dev/null || missing+=("aws-cli")
        command -v gpg &>/dev/null || missing+=("gpg")
        command -v tar &>/dev/null || missing+=("tar")

        if [[ ${#missing[@]} -gt 0 ]]; then
            die "Missing required commands: ${missing[*]}"
        fi

        if [[ -z "$S3_BUCKET" ]]; then
            die "S3_BUCKET is not configured. Set it in $CONFIG_FILE"
        fi

        if [[ -z "$GPG_RECIPIENT" ]]; then
            die "GPG_RECIPIENT is not configured. Set it in $CONFIG_FILE"
        fi

        # Verify GPG key exists
        if ! gpg --list-keys "$GPG_RECIPIENT" &>/dev/null; then
            die "GPG key for $GPG_RECIPIENT not found"
        fi

        # Verify S3 access
        if ! aws s3 ls "s3://${S3_BUCKET}" &>/dev/null; then
            die "Cannot access S3 bucket: $S3_BUCKET"
        fi
    }

    create_backup() {
        local timestamp
        timestamp=$(date '+%Y%m%d-%H%M%S')
        local backup_name="backup-${timestamp}"
        local temp_dir
        temp_dir=$(mktemp -d)

        # Ensure temp directory is cleaned up on exit
        trap 'rm -rf "$temp_dir"' EXIT

        log_info "Starting backup: $backup_name"

        # Collect existing paths
        local existing_paths=()
        for path in "${BACKUP_PATHS[@]}"; do
            if [[ -e "$path" ]]; then
                existing_paths+=("$path")
            else
                log_warn "Skipping non-existent path: $path"
            fi
        done

        if [[ ${#existing_paths[@]} -eq 0 ]]; then
            die "No files to backup"
        fi

        # Create tarball
        local tar_file="${temp_dir}/${backup_name}.tar.gz"
        log_info "Creating archive..."
        tar -czf "$tar_file" \
            --warning=no-file-changed \
            --exclude='*.pyc' \
            --exclude='__pycache__' \
            --exclude='.cache' \
            --exclude='node_modules' \
            --exclude='.git/objects' \
            "${existing_paths[@]}" 2>/dev/null || true

        local tar_size
        tar_size=$(du -h "$tar_file" | cut -f1)
        log_info "Archive size: $tar_size"

        # Encrypt with GPG
        local encrypted_file="${tar_file}.gpg"
        log_info "Encrypting with GPG (recipient: $GPG_RECIPIENT)..."
        gpg --batch --yes --trust-model always \
            --recipient "$GPG_RECIPIENT" \
            --output "$encrypted_file" \
            --encrypt "$tar_file"

        # Securely remove unencrypted tarball
        shred -u "$tar_file" 2>/dev/null || rm -f "$tar_file"

        local encrypted_size
        encrypted_size=$(du -h "$encrypted_file" | cut -f1)
        log_info "Encrypted size: $encrypted_size"

        # Upload to S3
        local s3_path="s3://${S3_BUCKET}/${S3_PREFIX}/${backup_name}.tar.gz.gpg"
        log_info "Uploading to $s3_path..."
        aws s3 cp "$encrypted_file" "$s3_path" \
            --storage-class STANDARD_IA \
            --only-show-errors

        log_info "Upload complete"

        # Verify upload
        if aws s3 ls "$s3_path" &>/dev/null; then
            log_info "Backup verified: $s3_path"
        else
            die "Backup verification failed"
        fi

        echo "$s3_path"
    }

    cleanup_old_backups() {
        log_info "Cleaning up backups older than $RETENTION_DAYS days..."

        local cutoff_date
        cutoff_date=$(date -d "-${RETENTION_DAYS} days" '+%Y-%m-%d' 2>/dev/null || \
                      date -v-${RETENTION_DAYS}d '+%Y-%m-%d')

        local deleted_count=0

        while IFS= read -r line; do
            # Parse S3 ls output: "2024-01-15 12:00:00 12345 filename"
            local file_date file_name
            file_date=$(echo "$line" | awk '{print $1}')
            file_name=$(echo "$line" | awk '{print $4}')

            if [[ -z "$file_name" ]]; then
                continue
            fi

            if [[ "$file_date" < "$cutoff_date" ]]; then
                log_info "Deleting old backup: $file_name"
                aws s3 rm "s3://${S3_BUCKET}/${S3_PREFIX}/${file_name}" --only-show-errors
                ((deleted_count++))
            fi
        done < <(aws s3 ls "s3://${S3_BUCKET}/${S3_PREFIX}/" 2>/dev/null || true)

        log_info "Deleted $deleted_count old backup(s)"
    }

    list_backups() {
        echo "Backups in s3://${S3_BUCKET}/${S3_PREFIX}/:"
        echo "---"
        aws s3 ls "s3://${S3_BUCKET}/${S3_PREFIX}/" --human-readable
    }

    restore_backup() {
        local backup_file="$1"
        local restore_dir="${2:-${HOME}/restored-backup}"

        if [[ -z "$backup_file" ]]; then
            die "Usage: $0 restore <backup-file> [restore-dir]"
        fi

        mkdir -p "$restore_dir"
        local temp_dir
        temp_dir=$(mktemp -d)
        trap 'rm -rf "$temp_dir"' EXIT

        local s3_path="s3://${S3_BUCKET}/${S3_PREFIX}/${backup_file}"
        local encrypted_file="${temp_dir}/${backup_file}"

        log_info "Downloading $s3_path..."
        aws s3 cp "$s3_path" "$encrypted_file" --only-show-errors

        log_info "Decrypting..."
        local tar_file="${encrypted_file%.gpg}"
        gpg --batch --yes --output "$tar_file" --decrypt "$encrypted_file"

        log_info "Extracting to $restore_dir..."
        tar -xzf "$tar_file" -C "$restore_dir"

        log_info "Restore complete: $restore_dir"
    }

    show_usage() {
        cat <<EOF
    Usage: $(basename "$0") [command]

    Commands:
        backup      Create and upload a new backup (default)
        list        List existing backups
        cleanup     Remove backups older than RETENTION_DAYS
        restore     Restore a backup: restore <filename> [target-dir]
        status      Show configuration and status

    Configuration file: $CONFIG_FILE

    Required settings:
        S3_BUCKET       S3 bucket name
        GPG_RECIPIENT   GPG key ID or email for encryption

    Optional settings:
        S3_PREFIX       S3 prefix (default: backups/\$(hostname))
        RETENTION_DAYS  Days to keep backups (default: 30)
        LOG_FILE        Log file path
    EOF
    }

    show_status() {
        echo "=== S3 Backup Configuration ==="
        echo "Config file:    $CONFIG_FILE"
        echo "S3 Bucket:      ${S3_BUCKET:-NOT SET}"
        echo "S3 Prefix:      ${S3_PREFIX}"
        echo "GPG Recipient:  ${GPG_RECIPIENT:-NOT SET}"
        echo "Retention:      ${RETENTION_DAYS} days"
        echo "Log file:       ${LOG_FILE}"
        echo ""
        echo "=== Backup Paths ==="
        for path in "${BACKUP_PATHS[@]}"; do
            if [[ -e "$path" ]]; then
                echo "  ✓ $path"
            else
                echo "  ✗ $path (not found)"
            fi
        done
    }

    main() {
        local command="${1:-backup}"

        case "$command" in
            backup)
                check_requirements
                create_backup
                cleanup_old_backups
                ;;
            list)
                check_requirements
                list_backups
                ;;
            cleanup)
                check_requirements
                cleanup_old_backups
                ;;
            restore)
                check_requirements
                restore_backup "${2:-}" "${3:-}"
                ;;
            status)
                show_status
                ;;
            -h|--help|help)
                show_usage
                ;;
            *)
                die "Unknown command: $command. Use --help for usage."
                ;;
        esac
    }

    main "$@"
  SCRIPT
end

# Create sample config if not exists
file "#{ENV['HOME']}/.config/s3-backup/config.sample" do
  owner user
  mode "0600"
  content <<~CONFIG
    # S3 Backup Configuration
    #
    # Copy this file to 'config' and fill in your values:
    #   cp config.sample config
    #
    # Required:
    S3_BUCKET=your-backup-bucket-name
    GPG_RECIPIENT=your-gpg-key-id-or-email

    # Optional:
    # S3_PREFIX=backups/$(hostname)
    # RETENTION_DAYS=30
    # LOG_FILE=${HOME}/.local/log/s3-backup.log
  CONFIG
  not_if "test -f #{ENV['HOME']}/.config/s3-backup/config.sample"
end

# Linux-specific: systemd user service and timer
if node[:platform] != "darwin"
  directory "#{ENV['HOME']}/.config/systemd/user" do
    owner user
    mode "0755"
  end

  file "#{ENV['HOME']}/.config/systemd/user/s3-backup.service" do
    owner user
    mode "0644"
    content <<~SERVICE
      [Unit]
      Description=S3 Backup Service - Securely backup sensitive files to S3
      After=network-online.target
      Wants=network-online.target

      [Service]
      Type=oneshot
      ExecStart=#{setup_root}/bin/s3-backup backup
      StandardOutput=journal
      StandardError=journal

      # Security hardening
      NoNewPrivileges=yes
      PrivateTmp=yes

      [Install]
      WantedBy=default.target
    SERVICE
  end

  file "#{ENV['HOME']}/.config/systemd/user/s3-backup.timer" do
    owner user
    mode "0644"
    content <<~TIMER
      [Unit]
      Description=Run S3 backup daily

      [Timer]
      # Run at 3:00 AM local time
      OnCalendar=*-*-* 03:00:00
      # Randomize start time within 30 minutes to avoid thundering herd
      RandomizedDelaySec=1800
      # Run missed backups on boot if system was off
      Persistent=true

      [Install]
      WantedBy=timers.target
    TIMER
  end

  # Reload systemd
  execute "systemctl --user daemon-reload" do
    user user
  end

  # Note: Timer is not automatically enabled
  # User should run after configuring ~/.config/s3-backup/config:
  #   systemctl --user enable --now s3-backup.timer
end

# Create README with usage instructions
file "#{setup_root}/bin/s3-backup.README.md" do
  owner user
  mode "0644"
  content <<~README
    # S3 Backup

    Securely backup sensitive files to S3 with GPG encryption.

    ## Setup

    1. Create S3 bucket (with appropriate IAM permissions)

    2. Configure the backup:
       ```bash
       cp ~/.config/s3-backup/config.sample ~/.config/s3-backup/config
       # Edit config with your S3 bucket and GPG key
       ```

    3. Test the backup:
       ```bash
       ~/.setup_shin1ohno/bin/s3-backup status
       ~/.setup_shin1ohno/bin/s3-backup backup
       ```

    4. Enable daily backups:
       ```bash
       systemctl --user enable --now s3-backup.timer
       ```

    ## Commands

    ```bash
    s3-backup backup   # Create and upload backup
    s3-backup list     # List existing backups
    s3-backup status   # Show configuration
    s3-backup restore <file> [dir]  # Restore a backup
    ```

    ## Restore on New Server

    1. Install GPG and import your private key
    2. Configure AWS CLI
    3. Run: `s3-backup restore backup-YYYYMMDD-HHMMSS.tar.gz.gpg`
  README
  not_if "test -f #{setup_root}/bin/s3-backup.README.md"
end
