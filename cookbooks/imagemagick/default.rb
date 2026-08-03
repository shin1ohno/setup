# frozen_string_literal: true

# Required by Neovim's snacks.image for JPEG/GIF/PDF/SVG → PNG conversion.
# snacks.image shells out to `magick` or `convert`; the Ubuntu package ships
# `convert` (v6) and macOS Homebrew ships both via the `imagemagick` formula.
install_package "imagemagick" do
  darwin "imagemagick"
  ubuntu "imagemagick"
  arch   "imagemagick"
end
