# frozen_string_literal: true
#
# python, linux half: the build dependencies pyenv needs before the shared
# half compiles an interpreter. macOS gets the equivalent headers from the
# Xcode Command Line Tools and Homebrew, so darwin.rb only includes the shared
# half.

# pyenv installs Python by compiling from source — Linux needs the dev
# headers up front, otherwise `pyenv install <ver>` builds Python without
# bz2 / ssl / readline / sqlite extensions and the post-install
# `pip install argcomplete` later fails for missing _ssl module.
%w[
  make build-essential libssl-dev zlib1g-dev libbz2-dev libreadline-dev
  libsqlite3-dev libncursesw5-dev xz-utils tk-dev libxml2-dev
  libxmlsec1-dev libffi-dev liblzma-dev
].each do |pkg|
  package pkg do
    user node[:setup][:system_user]
    not_if { run_command("dpkg-query -W -f='${Status}' #{pkg} 2>/dev/null | grep -q 'install ok installed'", error: false).exit_status == 0 }
  end
end

include_recipe "common"
