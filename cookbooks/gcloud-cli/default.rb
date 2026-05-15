# frozen_string_literal: true

installation_home = "#{node[:setup][:root]}/gcloud-cli"

directory installation_home do
  owner node[:setup][:user]
  mode "755"
end

# Get user information from node attributes
user = node[:setup][:user]
sdk_dir = "#{installation_home}/google-cloud-sdk"
gcloud_bin = "#{sdk_dir}/bin/gcloud"
zshrc_path = "#{installation_home}/.zshrc"

case node[:platform]
when "darwin"
  archive_name = "google-cloud-cli-darwin-arm.tar.gz"
  archive_path = "#{node[:setup][:root]}/gcloud-cli/#{archive_name}"

  execute "curl --silent --fail https://dl.google.com/dl/cloudsdk/channels/rapid/downloads/#{archive_name} -o #{archive_path.shellescape}" do
    user user
    not_if { File.exist?(archive_path) }
  end

  execute "tar -xzf #{archive_path.shellescape} -C #{installation_home}" do
    user user
    not_if { FileTest.directory?(sdk_dir) }
  end

  execute "#{sdk_dir}/install.sh --quiet --usage-reporting=false --path-update=true --command-completion=true --rc-path=#{zshrc_path} --additional-components alpha beta" do
    user user
    not_if "test -x #{gcloud_bin}"
  end

  add_profile "gcloud-cli" do
    bash_content <<~EOM
      # Lazy-load gcloud SDK: prepend SDK bin to PATH eagerly so `which
      # gcloud` works, but defer the heavy completion script until the
      # first gcloud / gsutil / bq invocation. path.zsh.inc only modifies
      # PATH so we inline its single export here. Saves ~50-100ms at
      # shell start.
      export PATH="#{sdk_dir}/bin:$PATH"
      for _gcloud_cmd in gcloud gsutil bq; do
        eval "${_gcloud_cmd}() { unset -f gcloud gsutil bq; source '#{sdk_dir}/completion.zsh.inc'; ${_gcloud_cmd} \\"\\$@\\"; }"
      done
      unset _gcloud_cmd
    EOM
  end
when "ubuntu", "debian"
  archive_path = "#{node[:setup][:root]}/gcloud-cli/google-cloud-cli-linux-x86_64.tar.gz"

  execute "curl --silent --fail https://dl.google.com/dl/cloudsdk/channels/rapid/downloads/google-cloud-cli-linux-x86_64.tar.gz -o #{archive_path.shellescape}" do
    user user
    not_if { File.exist?(archive_path) }
  end

  execute "tar -xzf #{archive_path.shellescape} -C #{installation_home}" do
    user user
    not_if { FileTest.directory?(sdk_dir) }
  end

  execute "#{sdk_dir}/install.sh --quiet --usage-reporting=false --path-update=true --command-completion=true --rc-path=#{zshrc_path} --additional-components alpha beta" do
    user user
    not_if "test -x #{gcloud_bin}"
  end

  add_profile "gcloud-cli" do
    bash_content <<~EOM
      # Lazy-load gcloud SDK — see darwin branch for rationale.
      export PATH="#{sdk_dir}/bin:$PATH"
      for _gcloud_cmd in gcloud gsutil bq; do
        eval "${_gcloud_cmd}() { unset -f gcloud gsutil bq; source '#{sdk_dir}/completion.zsh.inc'; ${_gcloud_cmd} \\"\\$@\\"; }"
      done
      unset _gcloud_cmd
    EOM
  end
else
  raise "Unsupported platform: #{node[:platform]}"
end
