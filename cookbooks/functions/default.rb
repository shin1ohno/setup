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
  # Non-TTY context (CI / agent-driven runs / `mitamae` invoked from a
  # background script): if `check_command` succeeds, the block runs
  # normally. If `check_command` fails, the block is SKIPPED with a
  # warning rather than yielded — yielding would queue resources that
  # fail at converge and abort the whole run, while skipping lets the
  # rest of the recipe proceed and the operator re-runs after configuring
  # auth. Downstream cookbooks that depend on the block's side effects
  # (e.g. .env files) should guard their consumers with `only_if "test
  # -f <path>"`.
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
    # user input AND the auth check failed. Skip the inner block entirely.
    # Yielding here would queue a resource that will fail at converge, which
    # aborts the whole mitamae run. Skipping with a loud warning lets the
    # rest of the recipe proceed; the user can re-run after configuring auth.
    unless STDIN.tty?
      MItamae.logger.warn("[bootstrap] #{tool_name} not configured AND STDIN is not a TTY — skipping auth-gated block. Configure auth and re-run mitamae to apply.")
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

# Normalize node[:platform]: PVE 9 LXC trixie templates report "debian"
# but ~13 cookbooks (awscli / golang / jdk / fzf / etc.) branch on
# "ubuntu" / "darwin" only and raise "Unsupported platform debian".
# apt is identical between Debian and Ubuntu, so alias once at the
# functions layer instead of patching `case node[:platform] when "ubuntu",
# "debian"` across every cookbook. Anything that genuinely needs to
# distinguish the two distros can read /etc/os-release directly.
node[:platform] = "ubuntu" if node[:platform] == "debian"

# Resolve host facts (setup paths, homebrew, identity) ONCE here, after the
# platform is normalized. Because functions is the universal first include of
# every entry recipe, this propagates node[:setup] / node[:homebrew] /
# node[:profile] to darwin.rb / linux.rb / pve/*.rb without each re-deriving
# them. See cookbooks/host-profile/default.rb.
include_cookbook "host-profile"

define :install_package, darwin: nil, ubuntu: nil, arch: nil do
  platform = node[:platform]
  pkgs = params[platform.to_sym]
  if pkgs
    Array(pkgs).each do |pkg|
      if platform == "darwin"
        package pkg
      else
        # Proc-form `not_if`: mitamae's specinfra check_package_is_installed
        # runs through the resource's `user` attribute (here system_user =
        # "root"), which on this host is wrapped with `sudo -u root` and
        # silently fails to non-zero — so the built-in idempotency check
        # always reports the package as not installed. The Proc evaluates
        # in mitamae's own Ruby context (no user wrap), so the dpkg-query
        # actually succeeds and suppresses the no-op apt-get install.
        package pkg do
          user node[:setup][:system_user]
          not_if { run_command("dpkg-query -W -f='${Status}' #{pkg} 2>/dev/null | grep -q 'install ok installed'", error: false).exit_status == 0 }
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

# Docker Compose service orchestration. Emits the two-resource pair every
# compose-using cookbook needs:
#
#   1. `execute "ensure <project> running"` — idempotency probe (docker
#      compose config --services + docker ps with compose-project label)
#      followed by `docker compose up -d`. Skip-or-run is decided by
#      whether the running services match the expected services. When
#      env_path is provided the probe gates on `test -f` first.
#
#   2. `execute "restart <project>"` — action :nothing, fires only via
#      notifies. Always passes `--force-recreate` because bare `up -d` is
#      a no-op when image + compose spec are unchanged, so bind-mounted
#      config edits don't take effect on already-running containers.
#      When env_path is provided, gated on `test -f` so the resource
#      doesn't restart against an empty env (e.g. SSM auth absent on a
#      fresh host before bootstrap).
#
# Retro knowledge baked in (see ~/.claude/rules/docker-compose.md):
#   --force-recreate mandatory; not_if "test -f env" mandatory when env
#   exists; DOCKER_BUILDKIT=0 prefix on privileged-LXC hosts whose
#   namespace hardening trips up BuildKit; --build flag default-on except
#   for cookbooks shipping pre-built images (ai-memory).
#
# Usage:
#   compose_service "cognee" do
#     compose_path "#{deploy_dir}/docker-compose.yml"
#     deploy_dir deploy_dir
#     env_path env_output_path           # optional; enables env-gate
#     buildkit false                     # optional (default true)
#     build_flag false                   # optional (default true; skip --build)
#     wait true                          # optional (default false)
#     wait_timeout 120                   # optional
#     user some_user                     # optional (default node[:setup][:user])
#     project_name "explicit"            # optional (default basename(deploy_dir))
#   end
#
# After the DSL call, notify the emitted resources via:
#   notifies :run, "execute[restart <project_name>]"
define :compose_service,
       compose_path: nil,
       deploy_dir: nil,
       project_name: nil,
       env_path: nil,
       user: nil,
       buildkit: true,
       build_flag: true,
       wait: false,
       wait_timeout: 120 do
  cp = params[:compose_path]
  pn = params[:project_name] || (params[:deploy_dir] && File.basename(params[:deploy_dir]))
  ep = params[:env_path]
  u  = params[:user] || node[:setup][:user]

  raise "compose_service requires :compose_path" unless cp
  raise "compose_service requires :deploy_dir or :project_name" unless pn

  buildkit_prefix = params[:buildkit] ? "" : "DOCKER_BUILDKIT=0 "
  build_arg = params[:build_flag] ? " --build" : ""
  wait_args = params[:wait] ? " --wait --wait-timeout #{params[:wait_timeout]}" : ""

  env_gate = ep ? "test -f #{ep} || exit 1; " : ""
  probe_sh = <<~SH.tr("\n", " ").strip
    #{env_gate}expected=$(docker compose -f #{cp} config --services 2>/dev/null | sort | tr '\\n' ' ');
    [ -n "$expected" ] || exit 1;
    running=$(docker ps --filter "label=com.docker.compose.project=#{pn}"
                        --filter status=running --format '{{.Label "com.docker.compose.service"}}'
              | sort | tr '\\n' ' ');
    test "$running" = "$expected" && exit 1 || exit 0
  SH

  ensure_command = "#{buildkit_prefix}docker compose -f #{cp} up -d#{build_arg}#{wait_args}"
  restart_command = "#{buildkit_prefix}docker compose -f #{cp} up -d#{build_arg} --force-recreate#{wait_args}"

  execute "ensure #{pn} running" do
    command ensure_command
    user u
    only_if probe_sh
  end

  execute "restart #{pn}" do
    command restart_command
    user u
    action :nothing
    only_if "test -f #{ep}" if ep
  end
end
