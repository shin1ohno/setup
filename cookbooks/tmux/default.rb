# frozen_string_literal: true

# tmux installation using mise
# Terminal multiplexer

# Ensure mise is installed
include_cookbook "mise"

mise_tool "tmux"
