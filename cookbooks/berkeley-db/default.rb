# frozen_string_literal: true

install_package "berkeley-db" do
  darwin "berkeley-db"
  ubuntu "libdb-dev"
  arch "db"
end
