if node[:platform] == 'darwin'
  openssl_dir = "#{node[:homebrew][:prefix]}/opt/openssl@1.1"

  package 'openssl@1.1' do
    not_if "test -d #{openssl_dir}"
  end

  env_prefixes = {
    'PATH' => {
      value: "#{openssl_dir}/bin",
      separator: ':',
    },
    'LDFLAGS' => {
      value: "-L#{openssl_dir}/lib",
      separator: ' ',
    },
    'CPPFLAGS' => {
      value: "-I#{openssl_dir}/include",
      separator: ' ',
    },
    'PKG_CONFIG_LIBDIR' => {
      value: "#{openssl_dir}/lib/pkgconfig",
      separator: ':',
    },
  }
  local_ruby_block 'Ensure openssl environment variables' do
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

  add_profile 'openssl' do
    bash_content(env_prefixes.map { |key, prefix|
      %Q{export #{key}="#{prefix[:value]}#{prefix[:separator]}$#{key}"}
    }.join("\n") + "\n")
    fish_content(env_prefixes.map { |key, prefix|
      %Q{set -gx #{key} #{prefix[:value]}#{prefix[:separator]}$#{key}}
    }.join("\n") + "\n")
  end

  local_ruby_block 'ensure OpenSSL 1.1 installation' do
    block do
      # Check command
      bin = File.readlink("#{node[:homebrew][:prefix]}/bin/openssl")
      if bin.start_with?('../Cellar/openssl/')
        raise "#{node[:homebrew][:prefix]}/bin/openssl is linked to legacy OpenSSL. Try this recovery procedure https://g.cookpad.com/hfm/20191129/174551#Homebrew%20%E9%96%A2%E9%80%A3%E3%81%AE%E3%83%91%E3%83%83%E3%82%B1%E3%83%BC%E3%82%B8%E3%82%92%E5%85%A5%E3%82%8C%E7%9B%B4%E3%81%97"
      end

      # Check headers
      headers = File.readlink("#{node[:homebrew][:prefix]}/include/openssl")
      if headers.start_with?('../Cellar/openssl/')
        raise "#{node[:homebrew][:prefix]}/include/openssl is linked to legacy OpenSSL. Try this recovery procedure https://g.cookpad.com/hfm/20191129/174551#Homebrew%20%E9%96%A2%E9%80%A3%E3%81%AE%E3%83%91%E3%83%83%E3%82%B1%E3%83%BC%E3%82%B8%E3%82%92%E5%85%A5%E3%82%8C%E7%9B%B4%E3%81%97"
      end

      # Check pkg-config
      result = run_command('pkg-config --libs openssl', error: false)
      if result.exit_status != 0
        raise 'pkg-config for openssl is broken'
      end
      if result.stdout.start_with?('-L/opt/brew/Cellar/openssl/')
        pc = File.readlink("#{node[:homebrew][:prefix]}/lib/pkgconfig/openssl.pc")
        if pc.start_with?('../../Cellar/openssl/')
          raise "#{node[:homebrew][:prefix]}/lib/pkgconfig/openssl.pc is linked to legacy OpenSSL. Try this recovery procedure https://g.cookpad.com/hfm/20191129/174551#Homebrew%20%E9%96%A2%E9%80%A3%E3%81%AE%E3%83%91%E3%83%83%E3%82%B1%E3%83%BC%E3%82%B8%E3%82%92%E5%85%A5%E3%82%8C%E7%9B%B4%E3%81%97"
        end
      end

      MItamae.logger.warn("#{node[:homebrew][:prefix]}/Cellar/openssl still exists. Please remove this directory to avoid troubles")
    end
    only_if { FileTest.directory?("#{node[:homebrew][:prefix]}/Cellar/openssl") }
  end
else
  install_package 'openssl' do
    ubuntu %w[openssl libssl-dev]
    arch 'openssl'
  end
end
