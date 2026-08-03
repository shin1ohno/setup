# frozen_string_literal: true
#
# pm2: the OS-independent profile half — the lazy-loading completion wrapper.
# Included LAST by darwin.rb and linux.rb (see install.rb for the other shared
# half).

add_profile "pm2" do
  bash_content <<~'EOM'
    # Lazy-load pm2 completion. The eager setup (bash-style `complete -F`)
    # adds ~3-5ms per shell and only matters when pm2 is tab-completed.
    # The wrapper unfunctions itself after registering completion + bash
    # compatibility shim.
    pm2() {
      unfunction pm2
      COMP_WORDBREAKS=${COMP_WORDBREAKS/=/}
      COMP_WORDBREAKS=${COMP_WORDBREAKS/@/}
      export COMP_WORDBREAKS
      autoload -U bashcompinit && bashcompinit
      _pm2_completion () {
        local si="$IFS"
        IFS=$'\n' COMPREPLY=($(COMP_CWORD="$COMP_CWORD" \
                               COMP_LINE="$COMP_LINE" \
                               COMP_POINT="$COMP_POINT" \
                               pm2 completion -- "${COMP_WORDS[@]}" \
                               2>/dev/null)) || return $?
        IFS="$si"
      }
      complete -o default -F _pm2_completion pm2
      command pm2 "$@"
    }
  EOM
end
