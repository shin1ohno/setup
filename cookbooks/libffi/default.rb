install_package 'libffi' do
  darwin 'libffi'
  ubuntu 'libffi-dev'
  arch 'libffi'
end

# libffi bundled with ffi gem fails to build on Xcode 10.
if node[:platform] == 'darwin'
  libffi_dir = "#{node[:homebrew][:prefix]}/opt/libffi"

  env_prefixes = {
    'LDFLAGS' => {
      value: "-L#{libffi_dir}/lib",
      separator: ' ',
    },
    'CPPFLAGS' => {
      value: "-I#{libffi_dir}/include",
      separator: ' ',
    },
    'PKG_CONFIG_LIBDIR' => {
      value: "#{libffi_dir}/lib/pkgconfig",
      separator: ':',
    },
  }
  local_ruby_block 'Ensure libffi environment variables' do
    block do
      env_prefixes.each do |key, prefix|
        unless ENV.fetch(key, '').include?(prefix[:value])
          MItamae.logger.info("Prepending '#{prefix[:value]}' to #{key} during this execution. (original: '#{ENV[key]}')")
          ENV[key] = "#{prefix[:value]}#{prefix[:separator]}#{ENV[key]}"
        end
      end
    end

    not_if do
      env_prefixes.all? { |key, prefix| ENV.fetch(key, '').include?(prefix[:value]) }
    end
  end

  add_profile 'libffi' do
    bash_content(env_prefixes.map { |key, prefix|
      %Q{export #{key}="#{prefix[:value]}#{prefix[:separator]}$#{key}"}
    }.join("\n") + "\n")
    fish_content(env_prefixes.map { |key, prefix|
      %Q{set -gx #{key} #{prefix[:value]}#{prefix[:separator]}$#{key}}
    }.join("\n") + "\n")
  end
end
