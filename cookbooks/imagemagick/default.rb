# frozen_string_literal: true

# Required by Neovim's snacks.image for JPEG/GIF/PDF/SVG → PNG conversion.
# snacks.image shells out to `magick` or `convert`; the Ubuntu package ships
# `convert` (v6) and macOS Homebrew ships both via the `imagemagick` formula.
case node[:platform]
when "ubuntu"
  package "imagemagick" do
    user node[:setup][:system_user]
    not_if { run_command("dpkg-query -W -f='${Status}' imagemagick 2>/dev/null | grep -q 'install ok installed'", error: false).exit_status == 0 }
  end
when "darwin"
  package "imagemagick"
else
  package "imagemagick" do
    user node[:setup][:system_user]
    not_if { run_command("dpkg-query -W -f='${Status}' imagemagick 2>/dev/null | grep -q 'install ok installed'", error: false).exit_status == 0 }
  end
end
