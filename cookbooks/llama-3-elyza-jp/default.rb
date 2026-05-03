# Same opt-out as cookbooks/ollama: an LXC without ollama installed
# (e.g. lxc-pro-dev) sets node[:llm][:skip_ollama] = true. Without
# this guard the `ollama create` execute below fails with
# "/bin/sh: 1: ollama: not found".
if node.dig(:llm, :skip_ollama)
  MItamae.logger.info("llama-3-elyza-jp: skipped (node[:llm][:skip_ollama] set)")
  return
end

result = run_command("ollama list | fgrep -q 'elyza:jp8b'", error: false)
return if result.exit_status == 0

model_dir = "#{node[:setup][:home]}/models/llm/llama-3-elyza-jp"

directory model_dir do
  owner node[:setup][:user]
  mode "0755"
  action :create
end

remote_file "#{model_dir}/download-llama-3-elyza-jp.sh" do
  source "files/download.sh"
  owner node[:setup][:user]
  mode "0755"
  action :create
end

remote_file "#{model_dir}/MODELFILE" do
  source "files/Modelfile"
  owner node[:setup][:user]
  mode "0755"
  action :create
end

execute "download-llama-3-elyza-jp" do
  command "#{model_dir}/download-llama-3-elyza-jp.sh #{model_dir}"
  user node[:setup][:user]
  not_if "ollama list | fgrep -q 'elyza:jp8b' || test -f #{model_dir}/Llama-3-ELYZA-JP-8B-q4_k_m.gguf"
end

execute "create ollama model file" do
  command "ollama create elyza:jp8b -f #{model_dir}/MODELFILE"
  user node[:setup][:user]
  not_if "ollama list | fgrep -q 'elyza:jp8b'"
end

execute "rm -rf ${model_dir}" do
  command "rm -rf #{model_dir}"
  only_if "ollama list | fgrep -q 'elyza:jp8b'"
end

