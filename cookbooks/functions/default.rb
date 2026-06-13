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

  # Collapse the LXC entry-recipe tail trio into one call:
  #   include_role "lxc-core"
  #   node.reverse_merge!(elastic_agent: { tags: tags, **extra })
  #   include_cookbook "elastic-agent"
  #
  # lxc-core bundles node-exporter + auto-mitamae-target; elastic-agent ships
  # the host's logs/metrics to the ES cluster tagged with `tags`. reverse_merge!
  # is first-wins, so a recipe that pre-sets node[:elastic_agent] keeps its value
  # (matches the prior inline form exactly).
  #
  # `elastic_agent_extra` carries per-host elastic-agent keys beyond tags (e.g.
  # monitoring's enable_prometheus_integration). pve/lxc-apm-server.rb opts out
  # (no lxc-core/elastic tail, not in the auto-mitamae hosts.json) by simply not
  # calling this.
  #
  # Usage:
  #   lxc_entry(tags: ["lxc", "cognee"])
  #   lxc_entry(tags: ["lxc", "monitoring"], elastic_agent_extra: { enable_prometheus_integration: true })
  def lxc_entry(tags:, elastic_agent_extra: {})
    include_role "lxc-core"
    node.reverse_merge!(elastic_agent: { tags: tags }.merge(elastic_agent_extra))
    include_cookbook "elastic-agent"
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
  #   - `tool_binary` (optional String): the CLI the check depends on (e.g.
  #     "aws"). If it isn't on PATH yet — or `check_command` exits 127 —
  #     the gate skips gracefully instead of looping, because this gate runs
  #     at COMPILE time while the tool's installer converges later. Looping
  #     would be a dead loop on a fresh machine. The installer still runs this
  #     converge; re-run mitamae to complete the gated work.
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
  def require_external_auth(tool_name:, check_command:, instructions:, skip_if: nil, tool_binary: nil)
    if skip_if && skip_if.call
      return
    end

    # First check before any prompting — covers the warm-rerun case.
    result = run_command(check_command, error: false)
    if result.exit_status == 0
      yield if block_given?
      return
    end

    # Prerequisite tool not installed yet → do NOT enter the prompt loop.
    # This gate runs during the COMPILE phase (it is a top-level recipe call),
    # but the cookbook that installs the tool (e.g. awscli via
    # `include_cookbook "awscli"`) only converges AFTER compile. So on a fresh
    # machine the binary cannot exist yet, and looping on STDIN.gets here is a
    # dead loop — pressing Enter re-runs the same check while still in the
    # compile phase, so the tool never appears (5 attempts later the procedural
    # "skip" raises and aborts the whole run). Detect this via exit 127
    # (command not found) or an explicit `tool_binary` that is not on PATH, and
    # skip gracefully: the installer resource still converges THIS run, and a
    # re-run completes the auth-gated work. This is distinct from "tool present
    # but auth unconfigured" (e.g. aws installed, profile missing), which still
    # loops so the user can `aws configure` and press Enter. See
    # ~/.claude/rules/ruby.md "Mitamae evaluation model — top-level Ruby is
    # compile-time".
    tool_missing =
      (tool_binary && run_command("command -v #{tool_binary} >/dev/null 2>&1", error: false).exit_status != 0) ||
      result.exit_status == 127
    if tool_missing
      named = tool_binary ? " '#{tool_binary}'" : ""
      MItamae.logger.warn("=" * 60)
      MItamae.logger.warn("[bootstrap] #{tool_name}: prerequisite tool#{named} not installed yet — skipping auth-gated work this run.")
      MItamae.logger.warn("The installer converges during this run; re-run mitamae to complete the gated work.")
      MItamae.logger.warn("=" * 60)
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

# Universal setup-dir bootstrap. functions/default is the FIRST include of every
# recipe (entry recipes, roles, and à-la-carte cookbook includes such as the CI
# synthetic test recipes), so creating these here guarantees node[:setup][:root]
# and profile.d exist before ANY cookbook writes under them — e.g. homebrew's
# `remote_file .../homebrew-install.sh` or `add_profile` entries. Previously only
# roles/foundation (formerly roles/core) created them, so a recipe that included a
# cookbook directly without the role bootstrap failed at the first write
# (`cp: .../homebrew-install.sh: No such file or directory`). Declared right after
# host-profile so node[:setup] is resolved; runs before any later include.
[
  node[:setup][:root],
  "#{node[:setup][:root]}/profile.d",
  "#{node[:setup][:root]}/bin",
].each do |dir|
  directory dir do
    owner node[:setup][:user]
    group node[:setup][:group]
    mode "755"
  end
end

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

# Install an already-staged systemd unit (service or timer) and activate it
# with the CORRECT sequence baked in. Collapses the install + daemon-reload +
# enable + restart/start boilerplate that ~17 cookbooks repeat.
#
# The CALLER stages the unit file with its own `remote_file ... source
# "files/<unit>"` and passes the resulting absolute path as :staging_path.
# Staging is NOT done here on purpose: a `remote_file source "files/..."`
# declared inside a `define` resolves relative to cookbooks/functions/, not
# the calling cookbook (mitamae define source-resolution quirk), so it would
# look for the unit under functions/files/. Staging stays in the caller (one
# line, resolves correctly); this helper owns the error-prone activation.
#
# Activation rules (see ~/.claude/rules/infrastructure.md "systemd Timer
# Verification Gate"):
#   - .service: daemon-reload + enable + restart. `restart` (not `enable
#     --now`) is required so a unit-file EDIT actually takes effect on an
#     already-running service — `enable --now` only starts a stopped unit.
#   - .timer:   daemon-reload + enable <timer> + restart <timer> + start
#     <companion .service>. `enable --now` is a no-op on an active timer, so
#     a cookbook-driven timer-body change never reloads without `restart`;
#     `start <service>` seeds the deactivation reference that
#     OnUnitInactiveSec timers need.
#
# The activate execute runs only on a real unit change (notified by the
# install execute, which is gated on `diff -q`), so re-applies are no-ops.
# Verify a timer after apply with `systemctl show <name> --property=Trigger`
# (a future timestamp; `n/a` means it will never fire) — NOT `is-active`.
#
# Usage (long-running service):
#   staged = "#{node[:setup][:root]}/node-exporter/node-exporter.service"
#   remote_file staged do
#     source "files/node-exporter.service"
#     owner node[:setup][:user]; group node[:setup][:group]; mode "644"
#   end
#   systemd_unit "node-exporter.service" do
#     staging_path staged
#   end
#
# Usage (timer + companion oneshot service; stage + install the service first):
#   systemd_unit "foo.service" do
#     staging_path foo_service_staged
#     start false                      # oneshot triggered only by the timer
#   end
#   systemd_unit "foo.timer" do
#     staging_path foo_timer_staged
#     companion_unit "foo.service"     # default: same basename + .service
#   end
#
# Params:
#   staging_path   (required) absolute path of the staged unit (caller stages it)
#   companion_unit optional (.timer only); the .service to `start` on activate
#   start          optional bool (default true); for a .service, false skips
#                  restart (oneshot units driven solely by a timer)
define :systemd_unit,
       staging_path: nil,
       companion_unit: nil,
       start: true do
  unit = params[:name]
  raise "systemd_unit name must end in .service or .timer (#{unit})" unless unit =~ /\.(service|timer)\z/

  staging = params[:staging_path]
  raise "systemd_unit '#{unit}' requires :staging_path (the caller stages the file)" unless staging

  is_timer    = unit.end_with?(".timer")
  system_path = "/etc/systemd/system/#{unit}"
  activate    = "systemd_unit activate #{unit}"

  execute "install #{unit}" do
    command "sudo install -m 644 -o root -g root #{staging} #{system_path}"
    not_if "diff -q #{staging} #{system_path} 2>/dev/null"
    notifies :run, "execute[#{activate}]"
  end

  cmds = ["sudo systemctl daemon-reload"]
  if is_timer
    svc = params[:companion_unit] || unit.sub(/\.timer\z/, ".service")
    cmds << "sudo systemctl enable #{unit}"
    cmds << "sudo systemctl restart #{unit}"
    cmds << "sudo systemctl start #{svc}"
  elsif params[:start]
    cmds << "sudo systemctl enable #{unit}"
    cmds << "sudo systemctl restart #{unit}"
  else
    # oneshot service driven by a sibling timer: load the new unit, do not run it.
    cmds << "sudo systemctl enable #{unit}"
  end

  execute activate do
    command cmds.join(" && ")
    action :nothing
  end
end

# Deploy an SSM-sourced .env file: gate on AWS auth, run a generator that
# writes a temp file, then place it atomically and clean up. Collapses the
# `require_external_auth + generate + remote_file + temp-delete` quartet that
# ~9 cookbooks repeat, and bakes in CONTENT-AWARE skip_if.
#
# skip_if (see ~/.claude/rules/ruby.md "SSM-sourced .env generator ... drops
# new KEY=VALUE lines silently"): the gate is skipped only when the output
# already contains EVERY key in :expected_keys. A plain `File.exist?` skip
# would make adding a key to the generator a silent no-op on hosts whose .env
# predates the change; the content check forces a re-fetch instead.
#
# Usage:
#   deploy_with_ssm_env "cognee" do
#     tool_name        "AWS CLI (profile=#{aws_profile}) for /cognee/* SSM"
#     check_command    "aws ssm get-parameter --name /cognee/llm-endpoint " \
#                      "--profile #{aws_profile} --region #{aws_region} >/dev/null 2>&1"
#     instructions     "Configure '#{aws_profile}' with ssm:GetParameter on /cognee/*."
#     generate_command "AWS_PROFILE=#{aws_profile} AWS_REGION=#{aws_region} " \
#                      "bash #{generate_env_script} #{env_temp_path}"
#     temp_path        env_temp_path
#     output_path      env_output_path
#     expected_keys    %w[LLM_API_KEY OTEL_EXPORTER_OTLP_HEADERS]
#     restart_resource "execute[restart cognee]"   # notified on output change
#   end
#
# IMPORTANT: keep :expected_keys in sync with every key the generator writes —
# that list IS the drift detector. :check_command and the generator's aws
# calls must use the same --profile/AWS_PROFILE (bin/lint-cookbooks enforces).
#
# Params:
#   tool_name, check_command, instructions  (required) -> require_external_auth
#   generate_command   (required) the shell that writes :temp_path
#   temp_path          (required) generator output, deleted after placement
#   output_path        (required) final .env path
#   expected_keys      array of KEY names for the content-aware skip_if
#   owner/group/mode   optional (defaults: setup user/group, "600")
#   restart_resource   optional "execute[...]" notified when output changes
#   user               optional generator user (default node[:setup][:user])
define :deploy_with_ssm_env,
       tool_name: nil,
       check_command: nil,
       instructions: nil,
       generate_command: nil,
       temp_path: nil,
       output_path: nil,
       expected_keys: [],
       owner: nil,
       group: nil,
       mode: "600",
       restart_resource: nil,
       user: nil do
  tp  = params[:temp_path]
  op  = params[:output_path]
  gen = params[:generate_command]
  raise "deploy_with_ssm_env '#{params[:name]}' requires :temp_path + :output_path" unless tp && op
  raise "deploy_with_ssm_env '#{params[:name]}' requires :generate_command" unless gen

  u      = params[:user] || node[:setup][:user]
  keys   = params[:expected_keys] || []
  rsrc   = params[:restart_resource]
  fowner = params[:owner] || node[:setup][:user]
  fgroup = params[:group] || node[:setup][:group]
  fmode  = params[:mode]

  content_aware_skip = lambda do
    next false unless File.exist?(op)
    body = File.read(op)
    keys.all? { |k| body.include?("#{k}=") }
  end

  require_external_auth(
    tool_name: params[:tool_name],
    check_command: params[:check_command],
    instructions: params[:instructions],
    skip_if: content_aware_skip,
  ) do
    execute "generate #{params[:name]} .env" do
      command gen
      user u
    end
  end

  remote_file op do
    source tp
    owner fowner
    group fgroup
    mode fmode
    only_if "test -f #{tp}"
    notifies :run, rsrc if rsrc
  end

  file tp do
    action :delete
    only_if "test -f #{tp}"
  end
end
