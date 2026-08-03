# frozen_string_literal: true
#
# libffi, linux half: libffi-dev lands in the default compiler search paths,
# so the package install (common.rb) is the whole story here. The darwin half
# additionally exports LDFLAGS / CPPFLAGS / PKG_CONFIG_LIBDIR for Homebrew's
# keg-only libffi (cookbooks/libffi/darwin.rb).
include_recipe "common"
