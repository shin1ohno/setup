# frozen_string_literal: true
#
# Evaluate cookbooks/mcp/darwin.rb (and the register.rb it includes from inside
# the auth gate) against a fixture home, and run its resources the way mitamae
# would, with the two pieces of mitamae that matter for the AWS identity:
#
#   * `require_external_auth` runs check_command in mitamae's own environment
#     (run_command, no sudo) and yields only when it exits 0; a failing check on
#     a non-TTY host skips the block (the real helper's non-TTY path).
#   * an `execute` that sets `user` runs as
#     `sudo -H -u <user> -- /bin/sh -c "<command>"` (mitamae 1.14
#     mrblib/mitamae/backend.rb), an `execute` without `user` runs as
#     `/bin/sh -c "<command>"`. The test puts a `sudo` stand-in on PATH that
#     applies sudo's env_reset, so a variable that is not forwarded explicitly
#     is gone inside the command.
#
# Usage: ruby render-darwin.rb RECIPE_DIR FIXTURE_HOME
# RECIPE_DIR holds darwin.rb, register.rb and files/ (the test passes a copy of
# the pre-fix recipes for its negative run). Prints "GATE ...", "RESOURCE ..."
# and "  | <output of a failed command>" lines; exits 1 when a resource fails
# (mitamae aborts the run there).
require "etc"
require "fileutils"
require "json"
require "open3"
require "shellwords"

module MItamae
  def self.logger
    Object.new.tap do |logger|
      %i[info warn].each { |level| logger.define_singleton_method(level) { |message| puts "#{level}: #{message}" } }
    end
  end
end

class DarwinFixture
  Result = Struct.new(:stdout, :exit_status)

  def initialize(recipe_dir, home)
    raise "fixture marker required" unless File.file?("#{home}/.fixture-home")

    @recipe_dir = recipe_dir
    @home = home
    @resources = []
    user = Etc.getpwuid(Process.uid).name
    group = Etc.getgrgid(Process.gid).name
    @node = { setup: { user: user, group: group, home: home, root: "#{home}/setup root" } }
  end

  attr_reader :node

  def platform_value(darwin:, linux:)
    darwin
  end

  def run_command(command, **_options)
    out, status = Open3.capture2e("/bin/sh", "-c", command)
    Result.new(out, status.exitstatus)
  end

  def include_recipe(name)
    return puts("RECIPE #{name} (prerequisites, not rendered)") if name == "common"

    path = File.join(@recipe_dir, "#{name}.rb")
    puts "RECIPE #{name}"
    instance_eval(File.read(path, encoding: "UTF-8"), path, 1)
  end

  def require_external_auth(tool_name:, check_command:, instructions:, skip_if: nil)
    puts "GATE check: #{check_command}"
    result = run_command(check_command)
    if result.exit_status == 0
      puts "GATE ok"
      yield if block_given?
    else
      puts "GATE failed (exit #{result.exit_status}); auth-gated block skipped"
      puts "GATE diagnosis: #{diagnosis(check_command)}" if ENV["RENDER_DIAGNOSE"] == "1"
    end
  end

  # The TTY path of the real helper shows `_auth_diagnosis` when a gate fails.
  # Evaluate the production RecipeHelper module (cookbooks/functions/default.rb,
  # between `module RecipeHelper` and its closing `end`) on a bare object that
  # runs commands through this fixture, and call it as the helper does.
  def diagnosis(check_command)
    functions = File.expand_path("../../functions/default.rb", __dir__)
    source = File.read(functions, encoding: "UTF-8")
    helper_source = source[/^module RecipeHelper\n.*?^end\n/m] or raise "RecipeHelper not found in #{functions}"
    TOPLEVEL_BINDING.eval(helper_source) unless defined?(::RecipeHelper)
    fixture = self
    helper = Object.new
    helper.extend(::RecipeHelper)
    helper.define_singleton_method(:run_command) { |command, **options| fixture.run_command(command, **options) }
    helper._auth_diagnosis(check_command, true)
  end

  def directory(path, &block)
    @resources << [:directory, path, collect(%i[owner group mode action], &block)]
  end

  def execute(name, &block)
    @resources << [:execute, name, collect(%i[command user only_if not_if action], &block)]
  end

  def local_ruby_block(name, &block)
    values = {}
    resource = resource_object
    resource.define_singleton_method(:block) { |&b| values[:block] = b }
    resource.define_singleton_method(:only_if) { |value = nil, &b| values[:only_if] = b || value }
    resource.instance_eval(&block)
    @resources << [:local_ruby_block, name, values]
  end

  # A resource block sees `node` and the helpers of the recipe it sits in.
  def resource_object
    fixture = self
    Object.new.tap do |resource|
      resource.define_singleton_method(:node) { fixture.node }
      resource.define_singleton_method(:platform_value) { |**kw| fixture.platform_value(**kw) }
    end
  end

  def collect(fields, &block)
    values = {}
    resource = resource_object
    fields.each { |field| resource.define_singleton_method(field) { |value = nil| values[field] = value } }
    resource.instance_eval(&block)
    values
  end

  def guard_ok?(values)
    return false if values[:only_if].is_a?(String) && !system("/bin/sh", "-c", values[:only_if], out: File::NULL, err: File::NULL)
    return false if values[:not_if].is_a?(String) && system("/bin/sh", "-c", values[:not_if], out: File::NULL, err: File::NULL)

    true
  end

  def run_execute(name, values)
    command = values.fetch(:command)
    if values[:user]
      out, status = Open3.capture2e("sudo", "-H", "-u", values[:user], "--", "/bin/sh", "-c", command)
      via = "sudo"
    else
      out, status = Open3.capture2e("/bin/sh", "-c", command)
      via = "direct"
    end
    puts "RESOURCE execute[#{name}] #{status.exitstatus == 0 ? 'ran' : 'FAILED'} via=#{via} status=#{status.exitstatus}"
    return if status.exitstatus == 0

    out.each_line { |line| puts "  | #{line}" }
    exit 1
  end

  def run
    instance_eval(File.read(File.join(@recipe_dir, "darwin.rb"), encoding: "UTF-8"), File.join(@recipe_dir, "darwin.rb"), 1)
    @resources.each do |kind, name, values|
      case kind
      when :directory
        FileUtils.mkdir_p(name)
      when :execute
        if guard_ok?(values)
          run_execute(name, values)
        else
          puts "RESOURCE execute[#{name}] skipped (guard)"
        end
      when :local_ruby_block
        if values[:only_if].nil? || values[:only_if].call
          values[:block].call
          puts "RESOURCE local_ruby_block[#{name}] ran"
        else
          puts "RESOURCE local_ruby_block[#{name}] skipped (guard)"
        end
      end
    end
  end
end

DarwinFixture.new(File.expand_path(ARGV.fetch(0)), File.expand_path(ARGV.fetch(1))).run
