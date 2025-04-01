#!/bin/sh
set -eu

#region logging setup
if [ "${MISE_DEBUG-}" = "true" ] || [ "${MISE_DEBUG-}" = "1" ]; then
  debug() {
    echo "$@" >&2
  }
else
  debug() {
    :
  }
fi

if [ "${MISE_QUIET-}" = "1" ] || [ "${MISE_QUIET-}" = "true" ]; then
  info() {
    :
  }
else
  info() {
    echo "$@" >&2
  }
fi

error() {
  echo "$@" >&2
  exit 1
}
#endregion

#region environment setup
get_os() {
  os="$(uname -s)"
  if [ "$os" = Darwin ]; then
    echo "macos"
  elif [ "$os" = Linux ]; then
    echo "linux"
  else
    error "unsupported OS: $os"
  fi
}

get_arch() {
  musl=""
  if type ldd >/dev/null 2>/dev/null; then
    libc=$(ldd /bin/ls | grep 'musl' | head -1 | cut -d ' ' -f1)
    if [ -n "$libc" ]; then
      musl="-musl"
    fi
  fi
  arch="$(uname -m)"
  if [ "$arch" = x86_64 ]; then
    echo "x64$musl"
  elif [ "$arch" = aarch64 ] || [ "$arch" = arm64 ]; then
    echo "arm64$musl"
  elif [ "$arch" = armv7l ]; then
    echo "armv7$musl"
  else
    error "unsupported architecture: $arch"
  fi
}

get_ext() {
  if [ -n "${MISE_INSTALL_EXT:-}" ]; then
    echo "$MISE_INSTALL_EXT"
  elif [ -n "${MISE_VERSION:-}" ] && echo "$MISE_VERSION" | grep -q '^v2024'; then
    # 2024 versions don't have zstd tarballs
    echo "tar.gz"
  elif tar_supports_zstd; then
    echo "tar.zst"
  elif command -v zstd >/dev/null 2>&1; then
    echo "tar.zst"
  else
    echo "tar.gz"
  fi
}

tar_supports_zstd() {
  # tar is bsdtar or version is >= 1.31
  if tar --version | grep -q 'bsdtar' && command -v zstd >/dev/null 2>&1; then
    true
  elif tar --version | grep -q '1\.(3[1-9]|[4-9][0-9]'; then
    true
  else
    false
  fi
}

shasum_bin() {
  if command -v shasum >/dev/null 2>&1; then
    echo "shasum"
  elif command -v sha256sum >/dev/null 2>&1; then
    echo "sha256sum"
  else
    error "mise install requires shasum or sha256sum but neither is installed. Aborting."
  fi
}

get_checksum() {
  version=$1
  os="$(get_os)"
  arch="$(get_arch)"
  ext="$(get_ext)"
  url="https://github.com/jdx/mise/releases/download/v${version}/SHASUMS256.txt"

  # For current version use static checksum otherwise
  # use checksum from releases
  if [ "$version" = "v2025.3.11" ]; then
    checksum_linux_x86_64="e9bcfcf37e4f0ad4cd028bee8bf07cafb6f2a5059af866c18a1b2aee3993b725  ./mise-v2025.3.11-linux-x64.tar.gz"
    checksum_linux_x86_64_musl="91b224e073b501bbb6ab7d9fe4cee2f0ffda2d97a36e98b4211f306c77660257  ./mise-v2025.3.11-linux-x64-musl.tar.gz"
    checksum_linux_arm64="957c1edea9d47b027014218574f14ac290ed905a33ce700e3d94681325de044b  ./mise-v2025.3.11-linux-arm64.tar.gz"
    checksum_linux_arm64_musl="0d6b07d89928e21df84c09ce8961a572214ddcf2ce788dbbed5a9307b1730e56  ./mise-v2025.3.11-linux-arm64-musl.tar.gz"
    checksum_linux_armv7="947c6a055f5106fe7943b2cf553032041c77090072d9b2f7fc94ff88e02a7ad1  ./mise-v2025.3.11-linux-armv7.tar.gz"
    checksum_linux_armv7_musl="ed005bd475a93460b1d271c6b74798017144a8d39a72875073aba6048e623fb8  ./mise-v2025.3.11-linux-armv7-musl.tar.gz"
    checksum_macos_x86_64="92bffc6ed2f90b47c8f6021ae19b0e9232545951c0b764ff4ebda5961a1237de  ./mise-v2025.3.11-macos-x64.tar.gz"
    checksum_macos_arm64="bc0502c309dfe85a8096350297fec7d0f5b97482cfd94145ecb026db0e21947a  ./mise-v2025.3.11-macos-arm64.tar.gz"
    checksum_linux_x86_64_zstd="f9543498f90e8b07169cea1c62404f1e736d698feb090ff02f05a977547b61fe  ./mise-v2025.3.11-linux-x64.tar.zst"
    checksum_linux_x86_64_musl_zstd="73661a2229e56c66b740dc5aee5e8e603b7df333ae156a66a59a763aeb84107e  ./mise-v2025.3.11-linux-x64-musl.tar.zst"
    checksum_linux_arm64_zstd="be805e88dc513c2c5d1af8376ad839071c2ae983f74dd8b703781c2bc2f3340b  ./mise-v2025.3.11-linux-arm64.tar.zst"
    checksum_linux_arm64_musl_zstd="0ca223cf6faeeac10b7797d2d2e8a1ad96e8c261b3e7fc3222227b915946597e  ./mise-v2025.3.11-linux-arm64-musl.tar.zst"
    checksum_linux_armv7_zstd="07a995ed8db7e85d43b8f88784028e0d0f3a8777b9efc40df71bd84f9baf9f0c  ./mise-v2025.3.11-linux-armv7.tar.zst"
    checksum_linux_armv7_musl_zstd="90f88af9eb3d4c1fdbf714d5db2a5a2ec988e3965eb45356d882f075c03c8ab6  ./mise-v2025.3.11-linux-armv7-musl.tar.zst"
    checksum_macos_x86_64_zstd="e03657c133285cca6369eed32a36cc93152d90e62febe2ca371d0ca4d9f35c22  ./mise-v2025.3.11-macos-x64.tar.zst"
    checksum_macos_arm64_zstd="0390e9511d0231fcd51cfd96fa4a2224e275a5f9f21aaa06297ad9e8866ee342  ./mise-v2025.3.11-macos-arm64.tar.zst"

    # TODO: refactor this, it's a bit messy
    if [ "$(get_ext)" = "tar.zst" ]; then
      if [ "$os" = "linux" ]; then
        if [ "$arch" = "x64" ]; then
          echo "$checksum_linux_x86_64_zstd"
        elif [ "$arch" = "x64-musl" ]; then
          echo "$checksum_linux_x86_64_musl_zstd"
        elif [ "$arch" = "arm64" ]; then
          echo "$checksum_linux_arm64_zstd"
        elif [ "$arch" = "arm64-musl" ]; then
          echo "$checksum_linux_arm64_musl_zstd"
        elif [ "$arch" = "armv7" ]; then
          echo "$checksum_linux_armv7_zstd"
        elif [ "$arch" = "armv7-musl" ]; then
          echo "$checksum_linux_armv7_musl_zstd"
        else
          warn "no checksum for $os-$arch"
        fi
      elif [ "$os" = "macos" ]; then
        if [ "$arch" = "x64" ]; then
          echo "$checksum_macos_x86_64_zstd"
        elif [ "$arch" = "arm64" ]; then
          echo "$checksum_macos_arm64_zstd"
        else
          warn "no checksum for $os-$arch"
        fi
      else
        warn "no checksum for $os-$arch"
      fi
    else
      if [ "$os" = "linux" ]; then
        if [ "$arch" = "x64" ]; then
          echo "$checksum_linux_x86_64"
        elif [ "$arch" = "x64-musl" ]; then
          echo "$checksum_linux_x86_64_musl"
        elif [ "$arch" = "arm64" ]; then
          echo "$checksum_linux_arm64"
        elif [ "$arch" = "arm64-musl" ]; then
          echo "$checksum_linux_arm64_musl"
        elif [ "$arch" = "armv7" ]; then
          echo "$checksum_linux_armv7"
        elif [ "$arch" = "armv7-musl" ]; then
          echo "$checksum_linux_armv7_musl"
        else
          warn "no checksum for $os-$arch"
        fi
      elif [ "$os" = "macos" ]; then
        if [ "$arch" = "x64" ]; then
          echo "$checksum_macos_x86_64"
        elif [ "$arch" = "arm64" ]; then
          echo "$checksum_macos_arm64"
        else
          warn "no checksum for $os-$arch"
        fi
      else
        warn "no checksum for $os-$arch"
      fi
    fi
  else
    if command -v curl >/dev/null 2>&1; then
      debug ">" curl -fsSL "$url"
      checksums="$(curl --compressed -fsSL "$url")"
    else
      if command -v wget >/dev/null 2>&1; then
        debug ">" wget -qO - "$url"
        stderr=$(mktemp)
        checksums="$(wget -qO - "$url")"
      else
        error "mise standalone install specific version requires curl or wget but neither is installed. Aborting."
      fi
    fi
    # TODO: verify with minisign or gpg if available

    checksum="$(echo "$checksums" | grep "$os-$arch.$ext")"
    if ! echo "$checksum" | grep -Eq "^([0-9a-f]{32}|[0-9a-f]{64})"; then
      warn "no checksum for mise $version and $os-$arch"
    else
      echo "$checksum"
    fi
  fi
}

#endregion

download_file() {
  url="$1"
  filename="$(basename "$url")"
  cache_dir="$(mktemp -d)"
  file="$cache_dir/$filename"

  info "mise: installing mise..."

  if command -v curl >/dev/null 2>&1; then
    debug ">" curl -#fLo "$file" "$url"
    curl -#fLo "$file" "$url"
  else
    if command -v wget >/dev/null 2>&1; then
      debug ">" wget -qO "$file" "$url"
      stderr=$(mktemp)
      wget -O "$file" "$url" >"$stderr" 2>&1 || error "wget failed: $(cat "$stderr")"
    else
      error "mise standalone install requires curl or wget but neither is installed. Aborting."
    fi
  fi

  echo "$file"
}

install_mise() {
  version="${MISE_VERSION:-v2025.3.11}"
  version="${version#v}"
  os="$(get_os)"
  arch="$(get_arch)"
  ext="$(get_ext)"
  install_path="${MISE_INSTALL_PATH:-$HOME/.local/bin/mise}"
  install_dir="$(dirname "$install_path")"
  tarball_url="https://github.com/jdx/mise/releases/download/v${version}/mise-v${version}-${os}-${arch}.${ext}"

  cache_file=$(download_file "$tarball_url")
  debug "mise-setup: tarball=$cache_file"

  debug "validating checksum"
  cd "$(dirname "$cache_file")" && get_checksum "$version" | "$(shasum_bin)" -c >/dev/null

  # extract tarball
  mkdir -p "$install_dir"
  rm -rf "$install_path"
  cd "$(mktemp -d)"
  if [ "$(get_ext)" = "tar.zst" ] && ! tar_supports_zstd; then
    zstd -d -c "$cache_file" | tar -xf -
  else
    tar -xf "$cache_file"
  fi
  mv mise/bin/mise "$install_path"
  info "mise: installed successfully to $install_path"
}

after_finish_help() {
  case "${SHELL:-}" in
  */zsh)
    info "mise: run the following to activate mise in your shell:"
    info "echo \"eval \\\"\\\$($install_path activate zsh)\\\"\" >> \"${ZDOTDIR-$HOME}/.zshrc\""
    info ""
    info "mise: run \`mise doctor\` to verify this is setup correctly"
    ;;
  */bash)
    info "mise: run the following to activate mise in your shell:"
    info "echo \"eval \\\"\\\$($install_path activate bash)\\\"\" >> ~/.bashrc"
    info ""
    info "mise: run \`mise doctor\` to verify this is setup correctly"
    ;;
  */fish)
    info "mise: run the following to activate mise in your shell:"
    info "echo \"$install_path activate fish | source\" >> ~/.config/fish/config.fish"
    info ""
    info "mise: run \`mise doctor\` to verify this is setup correctly"
    ;;
  *)
    info "mise: run \`$install_path --help\` to get started"
    ;;
  esac
}

install_mise
if [ "${MISE_INSTALL_HELP-}" != 0 ]; then
  after_finish_help
fi
