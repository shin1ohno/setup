execute "install ansible" do
  command "pip install ansible || ansible-galaxy collection install ansible.netcommon"
  not_if "pip list | grep ansible"
end

