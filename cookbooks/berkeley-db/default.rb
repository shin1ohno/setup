# frozen_string_literal: true

install_package "berkeley-db" do
  user node[:setup][:user]
  darwin "berkeley-db"
  ubuntu "libdb-dev"
  arch "db"
end
