# frozen_string_literal: true

git_clone "enhancd" do
  cwd node[:setup][:root]
  uri "https://github.com/b4b4r07/enhancd.git"
end

execute "git pull" do
  cwd "#{node[:setup][:root]}/enhancd"
end

add_profile "enhancd" do
  priority 99
  bash_content <<~EOS
    source "#{node[:setup][:root]}/enhancd/init.sh"
  EOS
end
