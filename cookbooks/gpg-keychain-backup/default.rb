# frozen_string_literal: true

#
# GPG Keychain Backup - Securely backup GPG keys to macOS Keychain
#
# macOS only - uses security command and Keychain
#

return unless node[:platform] == "darwin"

setup_root = node[:setup][:root]
user = node[:setup][:user]

directory "#{setup_root}/bin" do
  owner user
  mode "0755"
end

file "#{setup_root}/bin/gpg-keychain" do
  owner user
  mode "0755"
  content <<~'SCRIPT'
    #!/usr/bin/env bash
    #
    # GPG Keychain Backup - Save/restore GPG keys to macOS Keychain
    #
    # Low-risk strategy:
    # - GPG secret key is encrypted with additional passphrase before storage
    # - Stored in macOS Keychain (optionally synced to iCloud)
    # - Requires both Keychain access AND passphrase to restore
    #

    set -euo pipefail

    KEYCHAIN_SERVICE_PREFIX="gpg-secret-key"
    REVOCATION_SERVICE_PREFIX="gpg-revocation-cert"

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

    # List available GPG secret keys
    list_gpg_keys() {
        echo "Available GPG secret keys:"
        echo "---"
        gpg --list-secret-keys --keyid-format LONG 2>/dev/null || echo "No keys found"
    }

    # List keys saved in Keychain
    list_keychain_keys() {
        echo "GPG keys saved in Keychain:"
        echo "---"
        security dump-keychain 2>/dev/null | grep -E "\"svce\".*${KEYCHAIN_SERVICE_PREFIX}" | \
            sed 's/.*<blob>="\([^"]*\)".*/  \1/' || echo "No keys found in Keychain"
    }

    # Save GPG key to Keychain
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

        # Get key fingerprint for service name
        local fingerprint
        fingerprint=$(gpg --list-secret-keys --keyid-format LONG "$key_id" 2>/dev/null | \
                      grep -E "^sec" | head -1 | awk '{print $2}' | cut -d'/' -f2)

        local service_name="${KEYCHAIN_SERVICE_PREFIX}-${fingerprint}"

        log_info "Exporting key $key_id (fingerprint: $fingerprint)..."

        # Export secret key
        local temp_dir
        temp_dir=$(mktemp -d)
        trap 'rm -rf "$temp_dir"' EXIT

        local plain_key="${temp_dir}/secret.asc"
        local encrypted_key="${temp_dir}/secret.asc.gpg"

        gpg --export-secret-keys --armor "$key_id" > "$plain_key"

        # Encrypt with symmetric passphrase
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

        # Optionally save revocation certificate
        if [[ "$include_revocation" == "yes" ]]; then
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
        fi

        echo ""
        log_info "Backup complete!"
        echo ""
        echo "To restore on a new machine:"
        echo "  gpg-keychain restore $fingerprint"
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

        # Securely delete
        rm -P "$plain_file" 2>/dev/null || rm -f "$plain_file"

        echo ""
        log_info "Key restored successfully!"
        echo ""
        echo "You may want to trust the key:"
        echo "  gpg --edit-key $fingerprint"
        echo "  > trust"
        echo "  > 5 (ultimate)"
        echo "  > quit"
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
        local revocation_service="${REVOCATION_SERVICE_PREFIX}-${fingerprint}"

        read -rp "Delete $fingerprint from Keychain? [y/N] " confirm
        if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
            echo "Cancelled"
            exit 0
        fi

        security delete-generic-password -s "$service_name" &>/dev/null && \
            log_info "Deleted secret key from Keychain" || \
            log_warn "Secret key not found in Keychain"

        security delete-generic-password -s "$revocation_service" &>/dev/null && \
            log_info "Deleted revocation certificate from Keychain" || \
            log_warn "Revocation certificate not found in Keychain"
    }

    show_usage() {
        cat <<EOF
    GPG Keychain Backup - Securely backup GPG keys to macOS Keychain

    Usage: $(basename "$0") <command> [options]

    Commands:
        save [key-id]              Save GPG key to Keychain (encrypted)
        restore [fingerprint]      Restore GPG key from Keychain
        restore-revocation <fp>    Restore revocation certificate
        delete [fingerprint]       Delete key from Keychain
        list                       List keys in Keychain
        list-gpg                   List available GPG keys

    Security:
        - Keys are encrypted with AES-256 before storing in Keychain
        - You need BOTH Keychain access AND the encryption passphrase to restore
        - Revocation certificates are also backed up

    Examples:
        $(basename "$0") save 59E8544A4001372A
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
            restore)
                restore_key "${1:-}"
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
