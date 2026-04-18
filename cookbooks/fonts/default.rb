# frozen_string_literal: true

case node[:platform]
when "darwin"
  execute "brew install font-hack-nerd-font" do
    not_if "brew list | fgrep -q 'font-hack-nerd-font'"
  end

  execute "brew install font-sauce-code-pro-nerd-font" do
    not_if "brew list | fgrep -q 'font-sauce-code-pro-nerd-font'"
  end

  execute "brew tap yuru7/nerd-fonts" do
    not_if "brew tap | fgrep -q 'yuru7/nerd-fonts'"
  end

  execute "brew install font-udev-gothic-nf" do
    not_if "brew list | fgrep -q 'font-udev-gothic-nf'"
  end
end
