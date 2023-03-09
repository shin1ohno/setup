case node[:platform]
when "darwin"
  execute 'brew tap homebrew/cask-fonts && brew reinstall --cask font-hack-nerd-font' do
    not_if %q{brew list | fgrep -q 'font-hack-nerd-font'}
  end

  execute 'brew tap homebrew/cask-fonts && brew reinstall --cask font-sauce-code-pro-nerd-font' do
    not_if %q{brew list | fgrep -q 'font-sauce-code-pro-nerd-font'}
  end
end
