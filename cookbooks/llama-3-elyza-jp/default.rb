model_dir = "#{ENV['HOME']}/models/llm/llama-3-elyza-jp"

directory model_dir do
  owner node[:user]
  mode "0755"
  action :create
end

remote_file "#{model_dir}/download-llama-3-elyza-jp.sh" do
  source "files/download.sh"
  owner node[:user]
  mode "0755"
  action :create
end

remote_file "#{model_dir}/MODELFILE" do
  source "files/ModelFile"
  owner node[:user]
  mode "0755"
  action :create
end

execute "download-llama-3-elyza-jp" do
  command "#{model_dir}/download-llama-3-elyza-jp.sh #{model_dir}"
  user node[:user]
  not_if "test -f #{model_dir}/Llama-3-ELYZA-JP-8B-q4_k_m.gguf"
end

execute "create ollama model file" do
  command "ollama create elyza:jp8b -f #{model_dir}/MODELFILE"
  user node[:user]
  not_if "ollama list | fgrep -q 'elyza:jp8b'"
end

execute "rm -rf ${model_dir}" do
  only_if "ollama list | fgrep -q 'elyza:jp8b'"
end

