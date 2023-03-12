# frozen_string_literal: true

add_profile "ssh" do
  priority 10
  bash_content <<"EOM"
eval "$(ssh-agent)" > /dev/null
EOM
end
