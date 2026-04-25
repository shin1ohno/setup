# frozen_string_literal: true

case node[:platform]
when "ubuntu"
  package "universal-ctags" do
    user node[:setup][:system_user]
  end
when "darwin"
  # universal-ctags/ctags upstream publishes only source tarballs on
  # GitHub releases (no prebuilt darwin binary). mise's github backend
  # can't install it. brew's universal-ctags formula is the standard
  # darwin install path; keep it.
  package "universal-ctags"
  package "ctags" do
    action :remove
    only_if { brew_formula?("ctags") }
  end
else
  package "ctags" do
    user node[:setup][:system_user]
  end
end
