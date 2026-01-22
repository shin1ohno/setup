# frozen_string_literal: true

#
# GPG Backup - Securely backup GPG keys
#
# Two tools:
#   gpg-keychain      - macOS Keychain (local, iCloud sync) - for subkeys on daily machines
#   gpg-master-backup - AWS Secrets Manager (remote, cross-platform) - for master key disaster recovery
#

setup_root = node[:setup][:root]
user = node[:setup][:user]

directory "#{setup_root}/bin" do
  owner user
  mode "0755"
end

#
# gpg-keychain - macOS Keychain backup (macOS only)
#
if node[:platform] == "darwin"
  file "#{setup_root}/bin/gpg-keychain" do
    owner user
    mode "0755"
    content <<~'SCRIPT'
      #!/usr/bin/env bash
      #
      # GPG Keychain Backup - Save/restore GPG keys to macOS Keychain
      #
      # Strategy:
      # - GPG secret key exported with --export-options backup for full fidelity
      # - Encrypted with additional passphrase before storage
      # - Stored in macOS Keychain (optionally synced to iCloud)
      # - Requires both Keychain access AND passphrase to restore
      #

      set -euo pipefail

      KEYCHAIN_SERVICE_PREFIX="gpg-secret-key"
      KEYCHAIN_SUBKEY_PREFIX="gpg-secret-subkeys"
      REVOCATION_SERVICE_PREFIX="gpg-revocation-cert"
      OWNERTRUST_SERVICE="gpg-ownertrust"

      RED='\033[0;31m'
      GREEN='\033[0;32m'
      YELLOW='\033[1;33m'
      NC='\033[0m'

      log_info() { echo -e "${GREEN}[INFO]${NC} $*"; }
      log_warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
      log_error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }

      die() {
          log_error "$@"
          exit 1
      }

      check_macos() {
          [[ "$(uname)" == "Darwin" ]] || die "This script is macOS only"
      }

      # List available GPG secret keys with subkeys
      list_gpg_keys() {
          echo "Available GPG secret keys:"
          echo "---"
          gpg --list-secret-keys --keyid-format LONG 2>/dev/null || echo "No keys found"
      }

      # List keys saved in Keychain
      list_keychain_keys() {
          echo "GPG keys saved in Keychain:"
          echo "---"
          echo "Master keys:"
          security dump-keychain 2>/dev/null | grep -E "\"svce\".*${KEYCHAIN_SERVICE_PREFIX}-" | \
              sed 's/.*<blob>="\([^"]*\)".*/  \1/' || echo "  (none)"
          echo ""
          echo "Subkeys only:"
          security dump-keychain 2>/dev/null | grep -E "\"svce\".*${KEYCHAIN_SUBKEY_PREFIX}-" | \
              sed 's/.*<blob>="\([^"]*\)".*/  \1/' || echo "  (none)"
      }

      # Get fingerprint from key ID
      get_fingerprint() {
          local key_id="$1"
          gpg --list-secret-keys --keyid-format LONG "$key_id" 2>/dev/null | \
              grep -E "^sec" | head -1 | awk '{print $2}' | cut -d'/' -f2
      }

      # Save GPG key to Keychain (master + subkeys)
      save_key() {
          local key_id="$1"
          local include_revocation="${2:-yes}"

          if [[ -z "$key_id" ]]; then
              list_gpg_keys
              echo ""
              read -rp "Enter Key ID to backup: " key_id
          fi

          # Verify key exists
          if ! gpg --list-secret-keys "$key_id" &>/dev/null; then
              die "Key $key_id not found"
          fi

          local fingerprint
          fingerprint=$(get_fingerprint "$key_id")
          local service_name="${KEYCHAIN_SERVICE_PREFIX}-${fingerprint}"

          log_info "Exporting key $key_id (fingerprint: $fingerprint)..."

          local temp_dir
          temp_dir=$(mktemp -d)
          trap 'rm -rf "$temp_dir"' EXIT

          local plain_key="${temp_dir}/secret.asc"
          local encrypted_key="${temp_dir}/secret.asc.gpg"

          # Export with backup options for full fidelity
          gpg --export-options backup --export-secret-keys --armor "$key_id" > "$plain_key"

          log_info "Encrypting with additional passphrase..."
          echo ""
          echo "Enter a passphrase to protect this backup."
          echo "(You will need this passphrase to restore the key)"
          echo ""

          gpg --symmetric --armor --cipher-algo AES256 \
              --output "$encrypted_key" "$plain_key"

          # Securely delete plain key
          rm -P "$plain_key" 2>/dev/null || rm -f "$plain_key"

          # Check if already exists in Keychain
          if security find-generic-password -s "$service_name" &>/dev/null; then
              log_warn "Key already exists in Keychain. Updating..."
              security delete-generic-password -s "$service_name" &>/dev/null || true
          fi

          # Save to Keychain
          log_info "Saving to Keychain as '$service_name'..."
          security add-generic-password \
              -a "$USER" \
              -s "$service_name" \
              -l "GPG Secret Key: $fingerprint" \
              -w "$(cat "$encrypted_key")" \
              -U

          log_info "Secret key saved to Keychain"

          # Save revocation certificate
          if [[ "$include_revocation" == "yes" ]]; then
              save_revocation "$key_id" "$fingerprint" "$temp_dir"
          fi

          # Save ownertrust
          save_ownertrust

          echo ""
          log_info "Backup complete!"
          echo ""
          echo "To restore on a new machine:"
          echo "  gpg-keychain restore $fingerprint"
      }

      # Save subkeys only (for daily machines)
      save_subkeys() {
          local key_id="$1"

          if [[ -z "$key_id" ]]; then
              list_gpg_keys
              echo ""
              read -rp "Enter Key ID to backup subkeys: " key_id
          fi

          if ! gpg --list-secret-keys "$key_id" &>/dev/null; then
              die "Key $key_id not found"
          fi

          local fingerprint
          fingerprint=$(get_fingerprint "$key_id")
          local service_name="${KEYCHAIN_SUBKEY_PREFIX}-${fingerprint}"

          log_info "Exporting subkeys for $key_id (fingerprint: $fingerprint)..."

          local temp_dir
          temp_dir=$(mktemp -d)
          trap 'rm -rf "$temp_dir"' EXIT

          local plain_key="${temp_dir}/subkeys.asc"
          local encrypted_key="${temp_dir}/subkeys.asc.gpg"

          # Export subkeys only (master key becomes a stub)
          gpg --export-options backup --export-secret-subkeys --armor "$key_id" > "$plain_key"

          log_info "Encrypting with additional passphrase..."
          echo ""
          echo "Enter a passphrase to protect this backup."
          echo "(You will need this passphrase to restore)"
          echo ""

          gpg --symmetric --armor --cipher-algo AES256 \
              --output "$encrypted_key" "$plain_key"

          rm -P "$plain_key" 2>/dev/null || rm -f "$plain_key"

          if security find-generic-password -s "$service_name" &>/dev/null; then
              log_warn "Subkeys already exist in Keychain. Updating..."
              security delete-generic-password -s "$service_name" &>/dev/null || true
          fi

          log_info "Saving to Keychain as '$service_name'..."
          security add-generic-password \
              -a "$USER" \
              -s "$service_name" \
              -l "GPG Subkeys: $fingerprint" \
              -w "$(cat "$encrypted_key")" \
              -U

          log_info "Subkeys saved to Keychain"
          echo ""
          echo "To restore subkeys on a daily machine:"
          echo "  gpg-keychain restore-subkeys $fingerprint"
          echo ""
          echo "Note: After restore, master key will show as stub (sec#)"
      }

      # Save revocation certificate
      save_revocation() {
          local key_id="$1"
          local fingerprint="$2"
          local temp_dir="$3"

          local revocation_service="${REVOCATION_SERVICE_PREFIX}-${fingerprint}"
          local revocation_file="${temp_dir}/revocation.asc"

          log_info "Generating revocation certificate..."
          echo "y" | gpg --command-fd 0 --gen-revoke "$key_id" > "$revocation_file" 2>/dev/null || true

          if [[ -s "$revocation_file" ]]; then
              security delete-generic-password -s "$revocation_service" &>/dev/null || true
              security add-generic-password \
                  -a "$USER" \
                  -s "$revocation_service" \
                  -l "GPG Revocation Cert: $fingerprint" \
                  -w "$(cat "$revocation_file")" \
                  -U
              log_info "Revocation certificate saved to Keychain"
          else
              log_warn "Could not generate revocation certificate (may already exist)"
          fi
      }

      # Save ownertrust
      save_ownertrust() {
          local trust_data
          trust_data=$(gpg --export-ownertrust 2>/dev/null)

          if [[ -n "$trust_data" ]]; then
              security delete-generic-password -s "$OWNERTRUST_SERVICE" &>/dev/null || true
              security add-generic-password \
                  -a "$USER" \
                  -s "$OWNERTRUST_SERVICE" \
                  -l "GPG Owner Trust" \
                  -w "$trust_data" \
                  -U
              log_info "Owner trust saved to Keychain"
          fi
      }

      # Restore GPG key from Keychain
      restore_key() {
          local fingerprint="$1"

          if [[ -z "$fingerprint" ]]; then
              list_keychain_keys
              echo ""
              read -rp "Enter fingerprint to restore: " fingerprint
          fi

          local service_name="${KEYCHAIN_SERVICE_PREFIX}-${fingerprint}"

          log_info "Retrieving key from Keychain..."

          local encrypted_key
          if ! encrypted_key=$(security find-generic-password -s "$service_name" -w 2>/dev/null); then
              die "Key not found in Keychain: $service_name"
          fi

          local temp_dir
          temp_dir=$(mktemp -d)
          trap 'rm -rf "$temp_dir"' EXIT

          local encrypted_file="${temp_dir}/secret.asc.gpg"
          local plain_file="${temp_dir}/secret.asc"

          echo "$encrypted_key" > "$encrypted_file"

          log_info "Decrypting (enter the passphrase you used when saving)..."
          if ! gpg --decrypt --output "$plain_file" "$encrypted_file"; then
              die "Failed to decrypt. Wrong passphrase?"
          fi

          log_info "Importing key to GPG..."
          gpg --import "$plain_file"

          rm -P "$plain_file" 2>/dev/null || rm -f "$plain_file"

          # Restore ownertrust if available
          restore_ownertrust

          echo ""
          log_info "Key restored successfully!"
          echo ""
          echo "You may want to trust the key:"
          echo "  gpg --edit-key $fingerprint"
          echo "  > trust"
          echo "  > 5 (ultimate)"
          echo "  > quit"
      }

      # Restore subkeys only
      restore_subkeys() {
          local fingerprint="$1"

          if [[ -z "$fingerprint" ]]; then
              list_keychain_keys
              echo ""
              read -rp "Enter fingerprint to restore subkeys: " fingerprint
          fi

          local service_name="${KEYCHAIN_SUBKEY_PREFIX}-${fingerprint}"

          log_info "Retrieving subkeys from Keychain..."

          local encrypted_key
          if ! encrypted_key=$(security find-generic-password -s "$service_name" -w 2>/dev/null); then
              die "Subkeys not found in Keychain: $service_name"
          fi

          local temp_dir
          temp_dir=$(mktemp -d)
          trap 'rm -rf "$temp_dir"' EXIT

          local encrypted_file="${temp_dir}/subkeys.asc.gpg"
          local plain_file="${temp_dir}/subkeys.asc"

          echo "$encrypted_key" > "$encrypted_file"

          log_info "Decrypting (enter the passphrase you used when saving)..."
          if ! gpg --decrypt --output "$plain_file" "$encrypted_file"; then
              die "Failed to decrypt. Wrong passphrase?"
          fi

          log_info "Importing subkeys to GPG..."
          gpg --import "$plain_file"

          rm -P "$plain_file" 2>/dev/null || rm -f "$plain_file"

          restore_ownertrust

          echo ""
          log_info "Subkeys restored successfully!"
          echo ""
          echo "Note: Master key is a stub (sec#). You can sign/decrypt but cannot"
          echo "create new subkeys or certify other keys without the master key."
      }

      # Restore ownertrust
      restore_ownertrust() {
          local trust_data
          if trust_data=$(security find-generic-password -s "$OWNERTRUST_SERVICE" -w 2>/dev/null); then
              echo "$trust_data" | gpg --import-ownertrust 2>/dev/null || true
              log_info "Owner trust restored"
          fi
      }

      # Restore revocation certificate
      restore_revocation() {
          local fingerprint="$1"

          if [[ -z "$fingerprint" ]]; then
              die "Usage: gpg-keychain restore-revocation <fingerprint>"
          fi

          local service_name="${REVOCATION_SERVICE_PREFIX}-${fingerprint}"

          local revocation
          if ! revocation=$(security find-generic-password -s "$service_name" -w 2>/dev/null); then
              die "Revocation certificate not found in Keychain"
          fi

          local output_file="revocation-${fingerprint}.asc"
          echo "$revocation" > "$output_file"

          log_info "Revocation certificate saved to: $output_file"
          echo ""
          echo "To revoke the key (IRREVERSIBLE!):"
          echo "  gpg --import $output_file"
      }

      # Delete key from Keychain
      delete_key() {
          local fingerprint="$1"

          if [[ -z "$fingerprint" ]]; then
              list_keychain_keys
              echo ""
              read -rp "Enter fingerprint to delete: " fingerprint
          fi

          local service_name="${KEYCHAIN_SERVICE_PREFIX}-${fingerprint}"
          local subkey_service="${KEYCHAIN_SUBKEY_PREFIX}-${fingerprint}"
          local revocation_service="${REVOCATION_SERVICE_PREFIX}-${fingerprint}"

          read -rp "Delete $fingerprint from Keychain? [y/N] " confirm
          if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
              echo "Cancelled"
              exit 0
          fi

          security delete-generic-password -s "$service_name" &>/dev/null && \
              log_info "Deleted master key from Keychain" || \
              log_warn "Master key not found in Keychain"

          security delete-generic-password -s "$subkey_service" &>/dev/null && \
              log_info "Deleted subkeys from Keychain" || \
              log_warn "Subkeys not found in Keychain"

          security delete-generic-password -s "$revocation_service" &>/dev/null && \
              log_info "Deleted revocation certificate from Keychain" || \
              log_warn "Revocation certificate not found in Keychain"
      }

      show_usage() {
          cat <<EOF
      GPG Keychain Backup - Securely backup GPG keys to macOS Keychain

      Usage: $(basename "$0") <command> [options]

      Commands:
          save [key-id]              Save master key + subkeys to Keychain
          save-subkeys [key-id]      Save subkeys only (for daily machines)
          restore [fingerprint]      Restore master key + subkeys from Keychain
          restore-subkeys [fp]       Restore subkeys only (master becomes stub)
          restore-revocation <fp>    Restore revocation certificate
          delete [fingerprint]       Delete key from Keychain
          list                       List keys in Keychain
          list-gpg                   List available GPG keys

      Security:
          - Keys are exported with --export-options backup for full fidelity
          - Keys are encrypted with AES-256 before storing in Keychain
          - You need BOTH Keychain access AND the encryption passphrase
          - Revocation certificates and ownertrust are also backed up

      Subkey Workflow:
          On master key server:  gpg-keychain save <key-id>
          On daily machine:      gpg-keychain restore-subkeys <fingerprint>

      Examples:
          $(basename "$0") save 59E8544A4001372A
          $(basename "$0") save-subkeys 59E8544A4001372A
          $(basename "$0") restore 59E8544A4001372A
          $(basename "$0") list
      EOF
      }

      main() {
          check_macos

          local command="${1:-}"
          shift || true

          case "$command" in
              save)
                  save_key "${1:-}" "${2:-yes}"
                  ;;
              save-subkeys)
                  save_subkeys "${1:-}"
                  ;;
              restore)
                  restore_key "${1:-}"
                  ;;
              restore-subkeys)
                  restore_subkeys "${1:-}"
                  ;;
              restore-revocation)
                  restore_revocation "${1:-}"
                  ;;
              delete)
                  delete_key "${1:-}"
                  ;;
              list)
                  list_keychain_keys
                  ;;
              list-gpg)
                  list_gpg_keys
                  ;;
              -h|--help|help|"")
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
end

#
# gpg-master-backup - AWS Secrets Manager backup (Linux/macOS)
#
file "#{setup_root}/bin/gpg-master-backup" do
  owner user
  mode "0755"
  content <<~'SCRIPT'
    #!/usr/bin/env bash
    #
    # GPG Master Backup - Save/restore GPG master keys to AWS Secrets Manager
    #
    # Strategy:
    # - Master key exported with --export-options backup for full fidelity
    # - Client-side encrypted with passphrase (AES-256) before upload
    # - Stored in AWS Secrets Manager (encrypted again with KMS)
    # - Requires both AWS access AND passphrase to restore
    #
    # Prerequisites:
    # - AWS CLI configured with appropriate credentials
    # - Secrets Manager permissions (secretsmanager:*)
    #

    set -euo pipefail

    SECRET_PREFIX="gpg-master-key"
    SUBKEY_PREFIX="gpg-subkeys"
    REVOCATION_PREFIX="gpg-revocation"
    OWNERTRUST_SECRET="gpg-ownertrust"

    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    BLUE='\033[0;34m'
    NC='\033[0m'

    log_info() { echo -e "${GREEN}[INFO]${NC} $*"; }
    log_warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
    log_error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }
    log_debug() { [[ "${DEBUG:-}" == "1" ]] && echo -e "${BLUE}[DEBUG]${NC} $*" || true; }

    die() {
        log_error "$@"
        exit 1
    }

    check_requirements() {
        command -v aws &>/dev/null || die "AWS CLI is required. Install with: brew install awscli"
        command -v gpg &>/dev/null || die "GPG is required"

        # Check AWS credentials
        if ! aws sts get-caller-identity &>/dev/null; then
            die "AWS credentials not configured. Run: aws configure"
        fi
    }

    # List available GPG secret keys
    list_gpg_keys() {
        echo "Available GPG secret keys:"
        echo "---"
        gpg --list-secret-keys --keyid-format LONG 2>/dev/null || echo "No keys found"
    }

    # List keys saved in Secrets Manager
    list_secrets() {
        echo "GPG keys saved in AWS Secrets Manager:"
        echo "---"
        echo "Master keys:"
        aws secretsmanager list-secrets \
            --filter Key=name,Values="${SECRET_PREFIX}" \
            --query 'SecretList[].Name' \
            --output text 2>/dev/null | tr '\t' '\n' | sed 's/^/  /' || echo "  (none)"
        echo ""
        echo "Subkeys:"
        aws secretsmanager list-secrets \
            --filter Key=name,Values="${SUBKEY_PREFIX}" \
            --query 'SecretList[].Name' \
            --output text 2>/dev/null | tr '\t' '\n' | sed 's/^/  /' || echo "  (none)"
    }

    # Get fingerprint from key ID
    get_fingerprint() {
        local key_id="$1"
        gpg --list-secret-keys --keyid-format LONG "$key_id" 2>/dev/null | \
            grep -E "^sec" | head -1 | awk '{print $2}' | cut -d'/' -f2
    }

    # Save master key to Secrets Manager
    save_key() {
        local key_id="$1"

        if [[ -z "$key_id" ]]; then
            list_gpg_keys
            echo ""
            read -rp "Enter Key ID to backup: " key_id
        fi

        if ! gpg --list-secret-keys "$key_id" &>/dev/null; then
            die "Key $key_id not found"
        fi

        local fingerprint
        fingerprint=$(get_fingerprint "$key_id")
        local secret_name="${SECRET_PREFIX}/${fingerprint}"

        log_info "Exporting master key $key_id (fingerprint: $fingerprint)..."

        local temp_dir
        temp_dir=$(mktemp -d)
        trap 'rm -rf "$temp_dir"' EXIT

        local plain_key="${temp_dir}/master.asc"
        local encrypted_key="${temp_dir}/master.asc.gpg"

        # Export with backup options for full fidelity
        gpg --export-options backup --export-secret-keys --armor "$key_id" > "$plain_key"

        log_info "Encrypting with passphrase (client-side encryption)..."
        echo ""
        echo "Enter a passphrase to protect this backup."
        echo "(You will need this passphrase to restore - AWS cannot decrypt without it)"
        echo ""

        gpg --symmetric --armor --cipher-algo AES256 \
            --output "$encrypted_key" "$plain_key"

        # Securely delete plain key
        rm -f "$plain_key"
        sync

        # Check if secret exists
        if aws secretsmanager describe-secret --secret-id "$secret_name" &>/dev/null; then
            log_warn "Secret already exists. Updating..."
            aws secretsmanager put-secret-value \
                --secret-id "$secret_name" \
                --secret-string "$(cat "$encrypted_key")" \
                --output text > /dev/null
        else
            log_info "Creating new secret: $secret_name"
            aws secretsmanager create-secret \
                --name "$secret_name" \
                --description "GPG Master Key: $fingerprint" \
                --secret-string "$(cat "$encrypted_key")" \
                --output text > /dev/null
        fi

        log_info "Master key saved to Secrets Manager"

        # Save revocation certificate
        save_revocation "$key_id" "$fingerprint" "$temp_dir"

        # Save ownertrust
        save_ownertrust

        echo ""
        log_info "Backup complete!"
        echo ""
        echo "To restore on a new machine:"
        echo "  gpg-master-backup restore $fingerprint"
    }

    # Save subkeys only
    save_subkeys() {
        local key_id="$1"

        if [[ -z "$key_id" ]]; then
            list_gpg_keys
            echo ""
            read -rp "Enter Key ID to backup subkeys: " key_id
        fi

        if ! gpg --list-secret-keys "$key_id" &>/dev/null; then
            die "Key $key_id not found"
        fi

        local fingerprint
        fingerprint=$(get_fingerprint "$key_id")
        local secret_name="${SUBKEY_PREFIX}/${fingerprint}"

        log_info "Exporting subkeys for $key_id (fingerprint: $fingerprint)..."

        local temp_dir
        temp_dir=$(mktemp -d)
        trap 'rm -rf "$temp_dir"' EXIT

        local plain_key="${temp_dir}/subkeys.asc"
        local encrypted_key="${temp_dir}/subkeys.asc.gpg"

        gpg --export-options backup --export-secret-subkeys --armor "$key_id" > "$plain_key"

        log_info "Encrypting with passphrase..."
        echo ""
        echo "Enter a passphrase to protect this backup."
        echo ""

        gpg --symmetric --armor --cipher-algo AES256 \
            --output "$encrypted_key" "$plain_key"

        rm -f "$plain_key"
        sync

        if aws secretsmanager describe-secret --secret-id "$secret_name" &>/dev/null; then
            log_warn "Secret already exists. Updating..."
            aws secretsmanager put-secret-value \
                --secret-id "$secret_name" \
                --secret-string "$(cat "$encrypted_key")" \
                --output text > /dev/null
        else
            log_info "Creating new secret: $secret_name"
            aws secretsmanager create-secret \
                --name "$secret_name" \
                --description "GPG Subkeys: $fingerprint" \
                --secret-string "$(cat "$encrypted_key")" \
                --output text > /dev/null
        fi

        log_info "Subkeys saved to Secrets Manager"
        echo ""
        echo "To restore subkeys on a daily machine:"
        echo "  gpg-master-backup restore-subkeys $fingerprint"
    }

    # Save revocation certificate
    save_revocation() {
        local key_id="$1"
        local fingerprint="$2"
        local temp_dir="$3"

        local secret_name="${REVOCATION_PREFIX}/${fingerprint}"
        local revocation_file="${temp_dir}/revocation.asc"

        log_info "Generating revocation certificate..."
        echo "y" | gpg --command-fd 0 --gen-revoke "$key_id" > "$revocation_file" 2>/dev/null || true

        if [[ -s "$revocation_file" ]]; then
            if aws secretsmanager describe-secret --secret-id "$secret_name" &>/dev/null; then
                aws secretsmanager put-secret-value \
                    --secret-id "$secret_name" \
                    --secret-string "$(cat "$revocation_file")" \
                    --output text > /dev/null
            else
                aws secretsmanager create-secret \
                    --name "$secret_name" \
                    --description "GPG Revocation Cert: $fingerprint" \
                    --secret-string "$(cat "$revocation_file")" \
                    --output text > /dev/null
            fi
            log_info "Revocation certificate saved to Secrets Manager"
        else
            log_warn "Could not generate revocation certificate"
        fi
    }

    # Save ownertrust
    save_ownertrust() {
        local trust_data
        trust_data=$(gpg --export-ownertrust 2>/dev/null)

        if [[ -n "$trust_data" ]]; then
            if aws secretsmanager describe-secret --secret-id "$OWNERTRUST_SECRET" &>/dev/null; then
                aws secretsmanager put-secret-value \
                    --secret-id "$OWNERTRUST_SECRET" \
                    --secret-string "$trust_data" \
                    --output text > /dev/null
            else
                aws secretsmanager create-secret \
                    --name "$OWNERTRUST_SECRET" \
                    --description "GPG Owner Trust" \
                    --secret-string "$trust_data" \
                    --output text > /dev/null
            fi
            log_info "Owner trust saved to Secrets Manager"
        fi
    }

    # Restore master key
    restore_key() {
        local fingerprint="$1"

        if [[ -z "$fingerprint" ]]; then
            list_secrets
            echo ""
            read -rp "Enter fingerprint to restore: " fingerprint
        fi

        local secret_name="${SECRET_PREFIX}/${fingerprint}"

        log_info "Retrieving master key from Secrets Manager..."

        local encrypted_key
        if ! encrypted_key=$(aws secretsmanager get-secret-value \
            --secret-id "$secret_name" \
            --query 'SecretString' \
            --output text 2>/dev/null); then
            die "Key not found in Secrets Manager: $secret_name"
        fi

        local temp_dir
        temp_dir=$(mktemp -d)
        trap 'rm -rf "$temp_dir"' EXIT

        local encrypted_file="${temp_dir}/master.asc.gpg"
        local plain_file="${temp_dir}/master.asc"

        echo "$encrypted_key" > "$encrypted_file"

        log_info "Decrypting (enter the passphrase you used when saving)..."
        if ! gpg --decrypt --output "$plain_file" "$encrypted_file"; then
            die "Failed to decrypt. Wrong passphrase?"
        fi

        log_info "Importing key to GPG..."
        gpg --import "$plain_file"

        rm -f "$plain_file"
        sync

        restore_ownertrust

        echo ""
        log_info "Master key restored successfully!"
        echo ""
        echo "You may want to trust the key:"
        echo "  gpg --edit-key $fingerprint"
        echo "  > trust"
        echo "  > 5 (ultimate)"
        echo "  > quit"
    }

    # Restore subkeys only
    restore_subkeys() {
        local fingerprint="$1"

        if [[ -z "$fingerprint" ]]; then
            list_secrets
            echo ""
            read -rp "Enter fingerprint to restore subkeys: " fingerprint
        fi

        local secret_name="${SUBKEY_PREFIX}/${fingerprint}"

        log_info "Retrieving subkeys from Secrets Manager..."

        local encrypted_key
        if ! encrypted_key=$(aws secretsmanager get-secret-value \
            --secret-id "$secret_name" \
            --query 'SecretString' \
            --output text 2>/dev/null); then
            die "Subkeys not found in Secrets Manager: $secret_name"
        fi

        local temp_dir
        temp_dir=$(mktemp -d)
        trap 'rm -rf "$temp_dir"' EXIT

        local encrypted_file="${temp_dir}/subkeys.asc.gpg"
        local plain_file="${temp_dir}/subkeys.asc"

        echo "$encrypted_key" > "$encrypted_file"

        log_info "Decrypting (enter the passphrase you used when saving)..."
        if ! gpg --decrypt --output "$plain_file" "$encrypted_file"; then
            die "Failed to decrypt. Wrong passphrase?"
        fi

        log_info "Importing subkeys to GPG..."
        gpg --import "$plain_file"

        rm -f "$plain_file"
        sync

        restore_ownertrust

        echo ""
        log_info "Subkeys restored successfully!"
        echo ""
        echo "Note: Master key is a stub (sec#). You can sign/decrypt but cannot"
        echo "create new subkeys or certify other keys without the master key."
    }

    # Restore ownertrust
    restore_ownertrust() {
        local trust_data
        if trust_data=$(aws secretsmanager get-secret-value \
            --secret-id "$OWNERTRUST_SECRET" \
            --query 'SecretString' \
            --output text 2>/dev/null); then
            echo "$trust_data" | gpg --import-ownertrust 2>/dev/null || true
            log_info "Owner trust restored"
        fi
    }

    # Restore revocation certificate
    restore_revocation() {
        local fingerprint="$1"

        if [[ -z "$fingerprint" ]]; then
            die "Usage: gpg-master-backup restore-revocation <fingerprint>"
        fi

        local secret_name="${REVOCATION_PREFIX}/${fingerprint}"

        local revocation
        if ! revocation=$(aws secretsmanager get-secret-value \
            --secret-id "$secret_name" \
            --query 'SecretString' \
            --output text 2>/dev/null); then
            die "Revocation certificate not found in Secrets Manager"
        fi

        local output_file="revocation-${fingerprint}.asc"
        echo "$revocation" > "$output_file"

        log_info "Revocation certificate saved to: $output_file"
        echo ""
        echo "To revoke the key (IRREVERSIBLE!):"
        echo "  gpg --import $output_file"
    }

    # Delete key from Secrets Manager
    delete_key() {
        local fingerprint="$1"

        if [[ -z "$fingerprint" ]]; then
            list_secrets
            echo ""
            read -rp "Enter fingerprint to delete: " fingerprint
        fi

        local master_secret="${SECRET_PREFIX}/${fingerprint}"
        local subkey_secret="${SUBKEY_PREFIX}/${fingerprint}"
        local revocation_secret="${REVOCATION_PREFIX}/${fingerprint}"

        echo ""
        echo "This will delete the following secrets:"
        echo "  - $master_secret"
        echo "  - $subkey_secret"
        echo "  - $revocation_secret"
        echo ""
        read -rp "Are you sure? [y/N] " confirm
        if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
            echo "Cancelled"
            exit 0
        fi

        for secret in "$master_secret" "$subkey_secret" "$revocation_secret"; do
            if aws secretsmanager describe-secret --secret-id "$secret" &>/dev/null; then
                aws secretsmanager delete-secret \
                    --secret-id "$secret" \
                    --force-delete-without-recovery \
                    --output text > /dev/null
                log_info "Deleted: $secret"
            else
                log_warn "Not found: $secret"
            fi
        done
    }

    show_usage() {
        cat <<EOF
    GPG Master Backup - Securely backup GPG keys to AWS Secrets Manager

    Usage: $(basename "$0") <command> [options]

    Commands:
        save [key-id]              Save master key + subkeys to Secrets Manager
        save-subkeys [key-id]      Save subkeys only (for daily machine recovery)
        restore [fingerprint]      Restore master key + subkeys
        restore-subkeys [fp]       Restore subkeys only (master becomes stub)
        restore-revocation <fp>    Restore revocation certificate
        delete [fingerprint]       Delete key from Secrets Manager
        list                       List keys in Secrets Manager
        list-gpg                   List available GPG keys

    Security:
        - Keys are encrypted client-side with AES-256 before upload
        - Stored in Secrets Manager (encrypted again with KMS)
        - You need BOTH AWS access AND the encryption passphrase
        - Revocation certificates and ownertrust are also backed up

    Workflow:
        On master key server:  gpg-master-backup save <key-id>
        On daily machine:      gpg-master-backup restore-subkeys <fingerprint>

    Prerequisites:
        - AWS CLI configured (aws configure)
        - Secrets Manager permissions

    Examples:
        $(basename "$0") save 59E8544A4001372A
        $(basename "$0") restore 59E8544A4001372A
        $(basename "$0") list
    EOF
    }

    main() {
        check_requirements

        local command="${1:-}"
        shift || true

        case "$command" in
            save)
                save_key "${1:-}"
                ;;
            save-subkeys)
                save_subkeys "${1:-}"
                ;;
            restore)
                restore_key "${1:-}"
                ;;
            restore-subkeys)
                restore_subkeys "${1:-}"
                ;;
            restore-revocation)
                restore_revocation "${1:-}"
                ;;
            delete)
                delete_key "${1:-}"
                ;;
            list)
                list_secrets
                ;;
            list-gpg)
                list_gpg_keys
                ;;
            -h|--help|help|"")
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
