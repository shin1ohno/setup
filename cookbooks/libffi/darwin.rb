# frozen_string_literal: true
#
# libffi, darwin half: the keg-only Homebrew libffi needs LDFLAGS / CPPFLAGS /
# PKG_CONFIG_LIBDIR pointed at it, both for the rest of THIS mitamae run
# (local_ruby_block, so rbenv's Ruby build finds it) and for interactive
# shells (add_profile). Linux resolves libffi-dev through the default search
# paths and needs neither, so the split leaves linux.rb with just the shared
# package install.
include_recipe "common"

# libffi bundled with ffi gem fails to build on Xcode 10.
libffi_dir = "#{node[:homebrew][:prefix]}/opt/libffi"

env_prefixes = {
  "LDFLAGS" => {
    value: "-L#{libffi_dir}/lib",
    separator: " ",
  },
  "CPPFLAGS" => {
    value: "-I#{libffi_dir}/include",
    separator: " ",
  },
  "PKG_CONFIG_LIBDIR" => {
    value: "#{libffi_dir}/lib/pkgconfig",
    separator: ":",
  },
}
local_ruby_block "Ensure libffi environment variables" do
  block do
    env_prefixes.each do |key, prefix|
      unless ENV.fetch(key, "").include?(prefix[:value])
        MItamae.logger.info("Prepending '#{prefix[:value]}' to #{key} during this execution. (original: '#{ENV[key]}')")
        ENV[key] = "#{prefix[:value]}#{prefix[:separator]}#{ENV[key]}"
      end
    end
  end

  not_if do
    env_prefixes.all? { |key, prefix| ENV.fetch(key, "").include?(prefix[:value]) }
  end
end

add_profile "libffi" do
  bash_content(env_prefixes.map { |key, prefix|
    %Q{export #{key}="#{prefix[:value]}#{prefix[:separator]}$#{key}"}
  }.join("\n") + "\n")
  fish_content(env_prefixes.map { |key, prefix|
    "set -gx #{key} #{prefix[:value]}#{prefix[:separator]}$#{key}"
  }.join("\n") + "\n")
end
