# frozen_string_literal: true
#
# jdk, linux half: Amazon Corretto from its apt repository (the apt source is
# wired up by cookbooks/apt-source-corretto), plus java-common for the
# update-alternatives plumbing. The darwin half goes through mise instead
# (cookbooks/jdk/darwin.rb).
#
# install_package carries only the ubuntu key, so a platform without one
# raises — the same behaviour as the pre-split `else raise "Unsupported
# platform"` arm.
include_cookbook "apt-source-corretto"
install_package "java-common" do
  ubuntu "java-common"
end
