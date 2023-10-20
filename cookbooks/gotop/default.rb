execute "go install github.com/xxxserxxx/gotop/v4/cmd/gotop@latest" do
  not_if "which gotop"
end

