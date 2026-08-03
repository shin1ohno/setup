# frozen_string_literal: true
#
# terraform, darwin half: HashiCorp's own Homebrew tap.
#
# Split rather than a platform_value because the two platforms install through
# different package managers with differently-shaped commands — linux.rb wires
# up the apt repository instead. The pre-split default.rb expressed this as an
# `if darwin … return` guard over an apt `else` arm.
execute "brew tap hashicorp/tap && brew update" do
  not_if "brew tap | grep hashicorp/tap"
end

package "hashicorp/tap/terraform"
