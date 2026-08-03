# frozen_string_literal: true
#
# libffi: the OS-independent half — the package itself. Included FIRST by
# darwin.rb and linux.rb so resource order matches the pre-split default.rb
# exactly (install_package → darwin env plumbing).
install_package "libffi" do
  darwin "libffi"
  ubuntu "libffi-dev"
  arch "libffi"
end
