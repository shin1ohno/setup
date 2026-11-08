# frozen_string_literal: true

# The file-memory mirror hook comes from shin1ohno/ai-memory at the SHA pinned for
# CT 119 (ADR 0013), so one pin decides both sides of the hook/server contract.
# Its registration in files/settings.json stays in this cookbook: the hooks key is
# merged shallowly, and a split would leave a host with a registration but no body.
mirror_hook_pin = File.read(File.join(File.dirname(__FILE__), "..", "lxc-es-memory", "files", "ai-memory.pin")).strip
raise "ai-memory.pin must be one 40-hex SHA" unless mirror_hook_pin =~ /\A[0-9a-f]{40}\z/

mirror_hook_dest     = "#{node[:setup][:home]}/.claude/hooks/mirror-file-memory.rb"
mirror_hook_checkout = "#{node[:setup][:root]}/ai-memory-src"
mirror_hook_marker   = "#{node[:setup][:root]}/ai-memory-hook.sha"

# The global and system git config are ignored so a host's url rewrite cannot move
# this fetch onto SSH or a key. The marker is written last, so a partial run repeats.
execute "place mirror-file-memory.rb from the pinned ai-memory" do
  command <<~SH
    set -eu
    export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null GIT_TERMINAL_PROMPT=0
    PIN=#{mirror_hook_pin}
    CO=#{mirror_hook_checkout}
    mkdir -p "$CO"
    [ -d "$CO/.git" ] || git -C "$CO" init -q
    git -C "$CO" config remote.origin.url https://github.com/shin1ohno/ai-memory.git
    git -C "$CO" fetch -q --filter=blob:none origin +refs/heads/main:refs/remotes/origin/main
    git -C "$CO" merge-base --is-ancestor "$PIN" refs/remotes/origin/main
    mkdir -p "$CO/.git/info"
    echo '* -text -eol -ident -filter -working-tree-encoding' > "$CO/.git/info/attributes"
    git -C "$CO" -c advice.detachedHead=false checkout -q --force --detach "$PIN"
    [ "$(git -C "$CO" rev-parse HEAD)" = "$PIN" ]
    install -m 755 -o #{node[:setup][:user]} -g #{node[:setup][:group]} "$CO/hooks/mirror-file-memory.rb" #{mirror_hook_dest}
    want=$(git -C "$CO" ls-tree HEAD -- hooks/mirror-file-memory.rb | cut -f1 | cut -d' ' -f3)
    got=$(git hash-object --no-filters #{mirror_hook_dest})
    [ -n "$want" ] && [ "$want" = "$got" ]
    echo "$PIN" > #{mirror_hook_marker}
  SH
  not_if "test \"$(cat #{mirror_hook_marker} 2>/dev/null)\" = #{mirror_hook_pin} && test -f #{mirror_hook_dest}"
end
