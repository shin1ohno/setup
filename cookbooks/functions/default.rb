# frozen_string_literal: true

module RecipeHelper
  def include_role(name)
    include_role_or_cookbook(name, "roles")
  end

  def include_cookbook(name)
    include_role_or_cookbook(name, "cookbooks")
  end

  def include_role_or_cookbook(name, type)
    dir = File.expand_path("#{__FILE__}/../../..")
    names = name.split("::")
    names << "default" if names.length == 1
    names[-1] += ".rb"
    recipe_file = File.join(dir, type, *names)
    if File.exist?(recipe_file)
      include_recipe(recipe_file)
    else
      raise "#{type.capitalize} #{name} is not found at #{recipe_file}."
    end
  end

  # Pause mitamae and prompt the user to configure an external prerequisite
  # (AWS auth, GitHub SSH, etc.). Loops until `check_command` succeeds or the
  # user explicitly types "skip" after 5 attempts.
  #
  # Usage in a cookbook:
  #   await_external_auth(
  #     tool_name: "AWS CLI (sh1admn profile)",
  #     check_command: "aws sts get-caller-identity --profile sh1admn",
  #     instructions: "Run: aws configure --profile sh1admn",
  #   )
  #
  # Behaviour:
  #   - If check_command exits 0 immediately, returns silently — no prompt.
  #   - Else logs instructions and blocks on STDIN.gets, then re-checks.
  #   - After 5 failed attempts, offers a "skip" escape (raises if chosen)
  #     so a partial bootstrap can finish with a known gap.
  #
  # Caveat: STDIN.gets blocks in non-TTY contexts (CI, agent-driven runs).
  # The bootstrap is designed for an interactive first-time setup; non-
  # interactive runs should pre-configure auth before invoking mitamae.
  def await_external_auth(tool_name:, check_command:, instructions:)
    attempts = 0
    loop do
      result = run_command(check_command, error: false)
      return if result.exit_status == 0

      attempts += 1
      MItamae.logger.warn("=" * 60)
      MItamae.logger.warn("[bootstrap] #{tool_name} not configured (attempt #{attempts})")
      MItamae.logger.warn(instructions)
      MItamae.logger.warn("Press Enter to re-check, or Ctrl-C to abort.")
      MItamae.logger.warn("=" * 60)

      STDIN.gets

      if attempts >= 5
        MItamae.logger.warn("Still not configured after 5 attempts.")
        MItamae.logger.warn("Type 'skip' + Enter to bypass, or Enter alone to keep retrying.")
        response = (STDIN.gets || "").strip
        raise "User skipped #{tool_name} configuration" if response == "skip"
      end
    end
  end

  # Prepend dirs to mitamae's running ENV['PATH'] so subsequent execute
  # resources (and any `run_command` calls in this same mitamae run) see
  # them. Idempotent — entries already on PATH are skipped.
  #
  # Usage after installing a tool:
  #   prepend_path(
  #     "#{node[:setup][:home]}/.local/bin",
  #     "#{node[:setup][:home]}/.local/share/mise/shims",
  #   )
  #
  # Note: this is in-process only; it does NOT modify the user's shell
  # profile. Use `add_profile` for that. The two are complementary —
  # `prepend_path` covers within-run dependencies, `add_profile` covers
  # post-bootstrap login shells.
  def prepend_path(*dirs)
    dirs.each do |dir|
      next if ENV["PATH"].split(File::PATH_SEPARATOR).include?(dir)
      MItamae.logger.info("Prepending '#{dir}' to PATH for the rest of this run")
      ENV["PATH"] = "#{dir}#{File::PATH_SEPARATOR}#{ENV['PATH']}"
    end
  end
end
MItamae::RecipeContext.send(:include, RecipeHelper)

define :install_package, darwin: nil, ubuntu: nil, arch: nil do
  platform = node[:platform]
  pkgs = params[platform.to_sym]
  if pkgs
    Array(pkgs).each do |pkg|
      if platform == "darwin"
        package pkg
      else
        package pkg do
          user node[:setup][:system_user]
        end
      end
    end
  else
    raise "Unsupported platform #{node[:platform]}"
  end
end

define :add_profile, bash_content: nil, fish_content: nil, priority: 50 do
  bash_content = params[:bash_content]

  unless bash_content
    raise "add_profile requires bash_content"
  end

  priority = params[:priority]
  name = params[:name]

  file "#{node[:setup][:root]}/profile.d/#{priority}-#{name}.sh" do
    owner node[:setup][:user]
    group node[:setup][:group]
    mode "644"
    content bash_content
  end

  if ENV["SETUP_FISH"] == "1"
    fish_content = params[:fish_content]

    unless fish_content
      raise "add_profile requires fish_content"
    end

    file "#{node[:setup][:root]}/profile.d/#{priority}-#{name}.fish" do
      owner node[:setup][:user]
      group node[:setup][:group]
      mode "644"
      content fish_content
    end
  end
end

define :mise_tool, versions: nil, default_version: nil, backend: nil do
  tool = params[:name]
  backend = params[:backend]
  versions = params[:versions]
  prefix = backend ? "#{backend}:" : ""

  if versions
    # Pattern B: versioned (node, go)
    versions.each do |version|
      execute "$HOME/.local/bin/mise install #{prefix}#{tool}@#{version}" do
        user node[:setup][:user]
        not_if "$HOME/.local/bin/mise list #{prefix}#{tool} | grep -q '#{version}'"
      end
    end
    default_ver = params[:default_version] || versions.first
    execute "$HOME/.local/bin/mise use --global #{prefix}#{tool}@#{default_ver}" do
      user node[:setup][:user]
      not_if "$HOME/.local/bin/mise list #{prefix}#{tool} | grep '#{default_ver}' | grep -q 'config.toml'"
    end
  elsif backend
    # Pattern C: npm/cargo backend
    execute "install #{tool} via mise" do
      user node[:setup][:user]
      command "$HOME/.local/bin/mise use --global #{prefix}#{tool}@latest"
      not_if "$HOME/.local/bin/mise list | grep -q '#{prefix}#{tool}'"
    end
  else
    # Pattern A: simple tool@latest
    execute "$HOME/.local/bin/mise install #{tool}@latest" do
      user node[:setup][:user]
      not_if "$HOME/.local/bin/mise list #{tool} | grep -q '#{tool}'"
    end
    execute "$HOME/.local/bin/mise use --global #{tool}@latest" do
      user node[:setup][:user]
      not_if "$HOME/.local/bin/mise list #{tool} | grep -q 'config.toml'"
    end
  end
end

define :git_clone, uri: nil, cwd: nil, user: nil, not_if: nil do
  execute "git clone #{params[:uri]}" do
    action :run
    command "GIT_SSH_COMMAND='ssh -o BatchMode=yes -o ConnectTimeout=5' git clone #{params[:uri]}"
    cwd params[:cwd]
    user params[:user] || node[:setup][:user]
    not_if params[:not_if] || "test -e #{params[:cwd]}/#{params[:name]}"
  end
end
