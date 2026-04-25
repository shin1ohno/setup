# On macOS, brew refuses to run as root. The install_package helper handles
# the user-vs-system-user split per-platform — Mac runs as the mitamae user,
# Linux as system_user (sudo apt). Direct `package "sshpass" do user
# system_user end` would brew-as-root on Mac and fail with "Running Homebrew
# as root is extremely dangerous and no longer supported".
install_package "sshpass" do
  darwin "sshpass"
  ubuntu "sshpass"
  arch   "sshpass"
end

