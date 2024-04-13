execute "go get github.com/google/skicka" do
  not_if { "which skicka" }
end

