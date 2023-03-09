git_clone "enhancd" do
  cwd node[:setup][:root]
  uri "https://github.com/b4b4r07/enhancd.git"
end

add_profile "enhancd" do
  bash_content <<~EOS
    source "#{node[:setup][:root]}/enhancd/init.sh"
  EOS
end
