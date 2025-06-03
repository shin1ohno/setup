# frozen_string_literal: true

case node[:platform]
when "darwin"
  execute "brew install font-hack-nerd-font" do
    not_if "brew list | fgrep -q 'font-hack-nerd-font'"
  end

  execute "brew install font-sauce-code-pro-nerd-font" do
    not_if "brew list | fgrep -q 'font-sauce-code-pro-nerd-font'"
  end
end
