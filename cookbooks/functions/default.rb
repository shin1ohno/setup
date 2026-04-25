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

  # Gate a block of cookbook resources behind an external prerequisite
  # (AWS auth, GitHub SSH, etc.). Pauses mitamae and prompts the user to
  # configure the prerequisite, then runs the block.
  #
  # Usage:
  #   require_external_auth(
  #     tool_name: "AWS CLI",
  #     check_command: "aws sts get-caller-identity",
  #     instructions: "Run: aws configure",
  #     skip_if: -> { File.exist?(env_output_path) },  # optional
  #   ) do
  #     execute "generate .env" do
  #       command "bash #{generator}"
  #       not_if "test -f #{env_output_path}"
  #     end
  #   end
  #
  # Behaviour:
  #   - `skip_if` (optional callable): if it returns truthy, the auth check
  #     is skipped AND the block is not yielded — for cases where the work
  #     is already done (e.g. .env file exists). Resources inside the block
  #     would have been no-op'd by their own `not_if`, but skipping
  #     entirely also avoids a needless auth prompt on warm re-runs where
  #     auth happens to be unconfigured.
  #   - If `check_command` exits 0, the block runs immediately — no prompt.
  #   - Else logs instructions and blocks on STDIN.gets, then re-checks.
  #   - After 5 failed attempts, offers a "skip" escape: if the user types
  #     "skip", the block is NOT yielded and mitamae continues (partial
  #     bootstrap with a known gap). Anything else: keep retrying.
  #   - Without a block, behaves as a procedural gate (still pauses,
  #     returns when check passes; "skip" raises so the cookbook's
  #     unconditional resources still surface the missing prereq).
  #
  # Caveat: STDIN.gets blocks in non-TTY contexts. The bootstrap assumes
  # an interactive first-time run; non-interactive contexts should
  # pre-configure auth before invoking mitamae.
  def require_external_auth(tool_name:, check_command:, instructions:, skip_if: nil)
    if skip_if && skip_if.call
      return
    end

    # First check before any prompting — covers the warm-rerun case.
    result = run_command(check_command, error: false)
    if result.exit_status == 0
      yield if block_given?
      return
    end

    # Non-interactive context (CI / dry-run / agent-driven): can't pause for
    # user input. Skip the gate silently and yield the block. If the inner
    # resources actually need the auth, they'll fail at command-execution
    # time with a clearer downstream error than blocking on STDIN forever.
    unless STDIN.tty?
      MItamae.logger.warn("[bootstrap] #{tool_name} not configured but STDIN is not a TTY — skipping auth gate (non-interactive run).")
      yield if block_given?
      return
    end

    attempts = 0
    loop do
      attempts += 1
      MItamae.logger.warn("=" * 60)
      MItamae.logger.warn("[bootstrap] #{tool_name} not configured (attempt #{attempts})")
      MItamae.logger.warn(instructions)
      MItamae.logger.warn("Press Enter to re-check, or Ctrl-C to abort.")
      MItamae.logger.warn("=" * 60)

      STDIN.gets

      result = run_command(check_command, error: false)
      if result.exit_status == 0
        yield if block_given?
        return
      end

      if attempts >= 5
        MItamae.logger.warn("Still not configured after #{attempts} attempts.")
        MItamae.logger.warn("Type 'skip' + Enter to bypass this block, or Enter alone to keep retrying.")
        response = (STDIN.gets || "").strip
        if response == "skip"
          if block_given?
            MItamae.logger.warn("Skipping #{tool_name}-dependent block. Re-run mitamae after configuring.")
            return
          else
            raise "User skipped #{tool_name} configuration"
          end
        end
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

  # Cached lookups against `brew list --formula`, `brew list --cask`, and
  # `brew tap`. The cookbooks/homebrew recipe populates plain-text cache
  # files under #{node[:setup][:root]}/brew-cache/ at the start of a darwin
  # run. Each predicate reads its cache file on first call and memoizes;
  # subsequent calls are O(1).
  #
  # Why: each `brew list <name>` invocation pays the brew Ruby startup cost
  # (~hundreds of ms). With ~20 migrated tools × 3 lookups each (formula /
  # cask / tap), the savings are significant on darwin runs.
  #
  # Returns false if the cache file is missing (e.g. fresh machine before
  # homebrew cookbook ran, or non-darwin platforms). only_if blocks gated
  # on these predicates therefore safely no-op when the cache is absent.
  def brew_formula?(name)
    _brew_cache(:formulae).include?(name)
  end

  def brew_cask?(name)
    _brew_cache(:casks).include?(name)
  end

  def brew_tap?(name)
    _brew_cache(:taps).include?(name)
  end

  def _brew_cache(kind)
    @@brew_cache ||= {}
    return @@brew_cache[kind] if @@brew_cache.key?(kind)
    cache_root = "#{ENV['HOME']}/.setup_shin1ohno/brew-cache"
    file = "#{cache_root}/#{kind}.txt"
    @@brew_cache[kind] = File.exist?(file) ? File.read(file).split("\n").map(&:strip).reject(&:empty?) : []
  end
end
MItamae::RecipeContext.send(:include, RecipeHelper)
# only_if / not_if Procs evaluate in ResourceContext — include the helpers
# there too so brew_formula?, brew_cask?, brew_tap? resolve in those blocks.
MItamae::ResourceContext.send(:include, RecipeHelper)

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
