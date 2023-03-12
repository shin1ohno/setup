# frozen_string_literal: true

if node[:platform] == "darwin"
  # https://ghe.ckpd.co/tech-dept/ops/issues/2743
  package "gdbm-1.14" do
    action :remove
  end
end

install_package "gdbm" do
  darwin "gdbm"
  ubuntu "libgdbm-dev"
  arch "gdbm"
end
