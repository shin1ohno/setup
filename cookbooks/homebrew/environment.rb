# frozen_string_literal: true

env_prefixes = {
  "PATH" => "#{node[:homebrew][:prefix]}/bin:#{node[:homebrew][:prefix]}/sbin:",
  "CFLAGS" => "-isystem#{node[:homebrew][:prefix]}/include ",
  "CPPFLAGS" => "-isystem#{node[:homebrew][:prefix]}/include ",
  "LDFLAGS" => "-L#{node[:homebrew][:prefix]}/lib ",
}

pkg_config_libdir = %W[#{node[:homebrew][:prefix]}/lib/pkgconfig #{node[:homebrew][:prefix]}/share/pkgconfig /usr/lib/pkgconfig].join(File::PATH_SEPARATOR)

env_prefixes.merge("PKG_CONFIG_LIBDIR" => pkg_config_libdir).each do |key, value|
  unless ENV.fetch(key, "").include?(value)
    MItamae.logger.warn("Prepending '#{value}' to #{key} during this execution. (original: '#{ENV[key]}')")
    ENV[key] = "#{value}#{ENV[key]}"
  end
end
unless ENV.key?("HOMEBREW_DEV_CMD_RUN")
  ENV["HOMEBREW_DEV_CMD_RUN"] = "1"
end

add_profile "homebrew" do
  priority 10
  bash_content <<"EOM"
export PATH=#{env_prefixes['PATH']}$PATH
export CPPFLAGS="#{env_prefixes['CPPFLAGS']}$CPPFLAGS"
export CFLAGS="#{env_prefixes['CFLAGS']}$CFLAGS"
export LDFLAGS="#{env_prefixes['LDFLAGS']}$LDFLAGS"
export PKG_CONFIG_LIBDIR="#{pkg_config_libdir}"
export HOMEBREW_DEV_CMD_RUN=1
EOM

  fish_content <<EOM
set -gx PATH #{env_prefixes['PATH'].gsub(File::PATH_SEPARATOR, " ")} $PATH
set -gx CPPFLAGS #{env_prefixes['CPPFLAGS']}$CPPFLAGS
set -gx CFLAGS #{env_prefixes['CFLAGS']}$CFLAGS
set -gx LDFLAGS #{env_prefixes['LDFLAGS']}$LDFLAGS
set -gx PKG_CONFIG_LIBDIR #{pkg_config_libdir}
set -gx HOMEBREW_DEV_CMD_RUN 1
EOM
end
