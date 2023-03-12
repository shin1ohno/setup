# frozen_string_literal: true

package "thefuck"

add_profile "thefuck" do
  bash_content <<~EOS
    eval $(thefuck --alias)
  EOS
end
