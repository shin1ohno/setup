# macOS: use Homebrew (reliable on ARM), Linux: use mise asdf plugin
if node[:platform] == "darwin"
  package "fd"
else
  include_cookbook "mise"
  mise_tool "fd"
end
