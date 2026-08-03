# frozen_string_literal: true
#
# Nerd Fonts + UDEV Gothic NF, installed into the user font directory.
#
# darwin-only (see cookbooks/fonts/platform). The pre-migration recipe was a
# `case node[:platform]` whose only arm was `when "darwin"` and which carried no
# `else`, so on Linux it declared nothing and converged silently -- a dead
# branch that read as cross-platform coverage (and the sole remaining hit for
# lint check 11). roles/core now includes this cookbook behind a darwin
# condition, which is what actually shipped all along.
fonts_dir = "#{node[:setup][:home]}/Library/Fonts"
staging_dir = "#{node[:setup][:root]}/fonts"

directory staging_dir do
  owner node[:setup][:user]
  group node[:setup][:group]
  mode "755"
end

# Nerd Fonts from ryanoasis/nerd-fonts releases. The marker check uses a
# font filename present in each archive.
{
  "Hack" => { archive: "Hack.zip", marker: "HackNerdFont-Regular.ttf" },
  "SourceCodePro" => { archive: "SourceCodePro.zip", marker: "SauceCodeProNerdFont-Regular.ttf" },
}.each do |name, info|
  execute "install #{name} Nerd Font" do
    user node[:setup][:user]
    command <<~SH
      curl -L https://github.com/ryanoasis/nerd-fonts/releases/latest/download/#{info[:archive]} \
        -o #{staging_dir}/#{info[:archive]}
      unzip -o #{staging_dir}/#{info[:archive]} -d #{fonts_dir}/
      rm #{staging_dir}/#{info[:archive]}
    SH
    not_if "ls #{fonts_dir} 2>/dev/null | grep -q '#{info[:marker]}'"
  end
end

# UDEV Gothic NF — separate upstream (yuru7/udev-gothic).
execute "install UDEV Gothic NF" do
  user node[:setup][:user]
  command <<~SH
    url=$(curl -sL https://api.github.com/repos/yuru7/udev-gothic/releases/latest \
      | grep browser_download_url \
      | grep -E 'UDEVGothic_NF[^-]*\\.zip' \
      | head -n1 \
      | cut -d'"' -f4)
    curl -L "$url" -o #{staging_dir}/udev-gothic-nf.zip
    unzip -o -j #{staging_dir}/udev-gothic-nf.zip '*.ttf' -d #{fonts_dir}/
    rm #{staging_dir}/udev-gothic-nf.zip
  SH
  not_if "ls #{fonts_dir} 2>/dev/null | grep -qi 'UDEVGothic'"
end

# Cleanup brew-installed font casks/formulas. Cask names use dashes.
%w(font-hack-nerd-font font-sauce-code-pro-nerd-font font-udev-gothic-nf).each do |f|
  execute "brew uninstall --cask #{f}" do
    only_if { brew_cask?(f) }
  end
  execute "brew uninstall #{f}" do
    only_if { brew_formula?(f) }
  end
end
