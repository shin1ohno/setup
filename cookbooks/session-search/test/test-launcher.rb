# frozen_string_literal: true

# Evaluate the real recipe and execute its rendered launcher. Only identity
# discovery and sudo are fixtures: no root, deployment, network or secrets.
require "fileutils"
require "open3"
require "tmpdir"

class LauncherRecipe
  Result = Struct.new(:stdout, :exit_status)
  attr_reader :node, :files

  def initialize(home, root, env)
    @home, @root, @env = home, root, env
    @node = { profile: { label: "air", hostname: "fixture" },
              setup: { user: "shin1ohno", home: home, group: "fixture" } }
    @node.define_singleton_method(:reverse_merge!) { |values| merge!(values) }
    @files = {}
  end

  def run_command(command, **_options)
    case command
    when "id -u" then Result.new(@root ? "0\n" : "1000\n", 0)
    when "sh -c 'printf %s ~shin1ohno'" then Result.new(@home, 0)
    when "id -gn shin1ohno" then Result.new("fixture\n", 0)
    else
      out, err, status = Open3.capture3(@env, "/bin/sh", "-c", command)
      warn err unless err.empty?
      Result.new(out, status.exitstatus)
    end
  end

  def file(path, &block)
    resource = Object.new
    resource.define_singleton_method(:content) { |value| @content = value }
    %i[owner group mode only_if].each { |name| resource.define_singleton_method(name) { |_| } }
    resource.instance_eval(&block)
    @files[path] = resource.instance_variable_get(:@content)
  end

  # Resource bodies other than the launcher must never run in this harness.
  def directory(*); end
  def remote_file(*); end
  def execute(*); end
  def local_ruby_block(*); end
end

module MItamae
  def self.logger
    Object.new.tap { |logger| logger.define_singleton_method(:info) { |_| } }
  end
end

def assert(description, condition)
  raise "FAIL  #{description}" unless condition

  puts "PASS  #{description}"
end

recipe_path = File.expand_path("../common.rb", __dir__)
source = File.read(recipe_path)
real_python, status = Open3.capture2("python3", "-I", "-c", "import sys; print(sys.executable)")
raise "Python fixture unavailable" unless status.success?

Dir.mktmpdir("ccs-launcher-") do |work|
  home = "#{work}/user"
  root_bin = "#{work}/root-bin"
  shims = "#{home}/.pyenv/shims"
  python = "#{home}/.pyenv/versions/fixture/bin/python3"
  share = "#{home}/.local/share/session-search"
  FileUtils.mkdir_p([root_bin, shims, File.dirname(python), "#{share}/ccs", "#{home}/.local/bin"])
  File.symlink(real_python.strip, python)
  File.write("#{share}/ccs/__init__.py", "")
  File.write("#{share}/ccs/cli.py", "import sys\ndef main(args):\n print(sys.executable)\n print(repr(args))\n return 0\n")

  write_executable = lambda do |path, body|
    File.write(path, "#!/bin/sh\nset -eu\n#{body}\n")
    File.chmod(0o755, path)
  end
  write_executable.call("#{root_bin}/python3", "echo ROOT_PYTHON_MUST_NOT_RUN >&2; exit 91")
  write_executable.call("#{root_bin}/sudo", <<~SH)
    [ "$1 $2 $3 $4" = '-H -u shin1ohno --' ] || exit 92
    shift 4
    [ "$1 $2" = '/bin/sh -c' ] || exit 92
    export HOME="$CCS_TEST_HOME" PATH=/usr/bin:/bin
    exec "$@"
  SH
  shim_body = <<~SH
    [ "$HOME" = "$CCS_TEST_HOME" ] || exit 93
    [ "$PWD" = "$HOME" ] || exit 94
    [ "$PYENV_ROOT" = "$HOME/.pyenv" ] || exit 95
    [ -z "${PYENV_VERSION+x}" ] && [ -z "${PYENV_DIR+x}" ] || exit 96
    exec "$HOME/.pyenv/versions/fixture/bin/python3" "$@"
  SH
  write_executable.call("#{shims}/python3", shim_body)

  root_env = { "HOME" => work, "PATH" => "#{root_bin}:/usr/bin:/bin",
               "PYENV_ROOT" => "#{work}/root-pyenv", "PYENV_VERSION" => "root-only",
               "PYENV_DIR" => work, "CCS_TEST_HOME" => home }
  render = lambda do |root, env|
    recipe = LauncherRecipe.new(home, root, env)
    recipe.instance_eval("def evaluate_recipe\n#{source}\nend", recipe_path, 0)
    recipe.evaluate_recipe
    recipe.files.fetch("#{home}/.local/bin/ccs")
  end
  launcher = render.call(true, root_env)
  assert("root apply records the target user's real Python in launcher PY (got #{launcher.lines[4].strip})",
         launcher.include?(%(PY="#{python}")))

  launcher_path = "#{home}/.local/bin/ccs"
  File.write(launcher_path, launcher)
  File.chmod(0o755, launcher_path)
  out, err, status = Open3.capture3(root_env, launcher_path, "hello world", "--flag")
  assert("rendered launcher bypasses the root PATH and preserves arguments",
         status.success? && err.empty? && out.lines.map(&:strip) == [python, "['hello world', '--flag']"])

  user_env = root_env.merge("HOME" => home, "PATH" => File.dirname(python) + ":/usr/bin:/bin")
  assert("non-root apply still records its current Python", render.call(false, user_env).include?(%(PY="#{python}")))

  # A failed interpreter may write a plausible path before exiting nonzero.
  write_executable.call("#{shims}/python3", "echo #{python}; exit 1")
  assert("failed root probe leaves PY empty", render.call(true, root_env).include?('PY=""'))
  write_executable.call("#{shims}/python3", "echo relative/python3")
  assert("relative probe output leaves PY empty", render.call(true, root_env).include?('PY=""'))
  write_executable.call("#{shims}/python3", "exit 1")
  assert("unavailable target Python leaves PY empty", render.call(true, root_env).include?('PY=""'))

  File.unlink(python)
  fallback_env = user_env.merge("PATH" => File.dirname(real_python.strip) + ":/usr/bin:/bin")
  out, err, status = Open3.capture3(fallback_env, launcher_path, "fallback")
  assert("removed recorded Python falls back to PATH", status.success? && err.empty? && out.include?("['fallback']"))
end

puts "OK: all launcher cases passed"
