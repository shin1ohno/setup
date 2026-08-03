# frozen_string_literal: true
#
# jdk, darwin half: Corretto via mise, plus the cached JAVA_HOME export and
# the cleanup of the legacy Homebrew casks this cookbook used to install.
# The linux half installs Corretto from Amazon's apt repository instead
# (cookbooks/jdk/linux.rb) — different package managers, different resources,
# hence a split rather than a platform_value.
include_cookbook "mise"
mise_tool "java" do
  versions ["corretto-11", "corretto-17"]
  default_version "corretto-17"
end

add_profile "java" do
  bash_content <<~'EOS'
    # Cache JAVA_HOME from `mise where java@corretto-17`. Without the
    # cache, this profile entry spawns a 100-120ms mise subprocess on
    # every shell start. Regenerate when the mise binary itself changes
    # (any java install/update bumps mise's tools registry mtime).
    _sh1_java_cache="${XDG_CACHE_HOME:-$HOME/.cache}/java-home"
    _sh1_mise_bin="$HOME/.local/bin/mise"
    if [ -x "$_sh1_mise_bin" ]; then
      [ -d "$(dirname "$_sh1_java_cache")" ] || mkdir -p "$(dirname "$_sh1_java_cache")"
      if [ ! -s "$_sh1_java_cache" ] || [ "$_sh1_java_cache" -ot "$_sh1_mise_bin" ]; then
        "$_sh1_mise_bin" where java@corretto-17 2>/dev/null > "$_sh1_java_cache"
      fi
      [ -s "$_sh1_java_cache" ] && export JAVA_HOME="$(cat "$_sh1_java_cache")"
    fi
    unset _sh1_java_cache _sh1_mise_bin
  EOS
  fish_content "set -gx JAVA_HOME ($HOME/.local/bin/mise where java@corretto-17 2>/dev/null)\n"
end

# Cleanup legacy brew casks. Cask name uses '@' which brew normalizes to
# '@' in `brew list --cask` output (e.g. corretto@11).
%w(corretto@11 corretto@17).each do |cask|
  execute "brew uninstall --cask #{cask}" do
    only_if { brew_cask?(cask) }
  end
end
