package "autojump"

add_profile "autojump" do
  bash_content <<"EOF"
eval "$(jump shell zsh)"
EOF
end
