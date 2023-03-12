# frozen_string_literal: true

install_package "readline" do
  darwin "readline"
  ubuntu "libreadline-dev"
  arch "readline"
end
