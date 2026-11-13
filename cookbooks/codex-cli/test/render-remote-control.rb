# frozen_string_literal: true
#
# Evaluate cookbooks/codex-cli/remote_control.rb against a fixture HOME and
# run its resources the way mitamae would: guards first, remote_file only on a
# content change, notified executes once at the end. Every command runs through
# /bin/sh with the fixture's PATH (a recording `systemctl` stand-in), and the
# user-bus path /run/user/<uid> is retargeted into the fixture so a test can
# create or omit the bus socket. Nothing touches the real user manager.
#
# Usage: ruby render-remote-control.rb RECIPE FIXTURE_HOME
# Prints one "RESOURCE <kind>[<name>] <ran|skipped|changed|unchanged> as <user>"
# line per resource (the user/owner mitamae would run or chown it as; the
# fixture itself never switches users) and "WARN: ..." lines from commands on
# stderr.
require "fileutils"
require "open3"

module MItamae
  def self.logger
    Object.new.tap do |logger|
      %i[info warn].each { |level| logger.define_singleton_method(level) { |message| puts "#{level}: #{message}" } }
    end
  end
end

class RemoteControlFixture
  Result = Struct.new(:stdout, :exit_status)

  def initialize(path, home)
    raise "fixture marker required" unless File.file?("#{home}/.fixture-home")

    @path = path
    @home = home
    @resources = []
    # FIXTURE_UID=0 models pro-dev's auto-apply: mitamae runs as root, so
    # node[:setup] is root's, and the recipe resolves the workstation user
    # itself (answered below from FIXTURE_ROOT_HOME; empty = unresolvable).
    @uid = ENV.fetch("FIXTURE_UID", "1000")
    setup_user = @uid == "0" ? "root" : ENV.fetch("USER", "runner")
    @node = { codex_cli: { remote_control: ENV.fetch("FIXTURE_ATTRIBUTE", "true") == "true" },
              setup: { user: setup_user, group: "fixture", home: @uid == "0" ? "/root" : home } }
  end

  attr_reader :node

  def run_command(command, **_options)
    return Result.new("#{@uid}\n", 0) if command == "id -u"
    if command.include?("printf %s ~")
      root_home = ENV.fetch("FIXTURE_ROOT_HOME", @home)
      return Result.new(root_home.empty? ? command[/~\w+/] : root_home, 0)
    end
    return Result.new("fixture\n", 0) if command.start_with?("id -gn ")

    out, _err, status = Open3.capture3("/bin/sh", "-c", command)
    Result.new(out, status.exitstatus)
  end

  def retarget(command)
    command.gsub("/run/user/", "#{@home}/run/user/")
  end

  %i[directory remote_file execute].each do |kind|
    define_method(kind) do |name, &block|
      values = { action: :run }
      resource = Object.new
      %i[owner group mode only_if not_if source command user action].each do |field|
        resource.define_singleton_method(field) { |value = nil| values[field] = value }
      end
      resource.define_singleton_method(:notifies) { |_action, target| values[:notifies] = target }
      resource.instance_eval(&block)
      @resources << [kind, name, values]
    end
  end

  def sh(command)
    system("/bin/sh", "-c", retarget(command), out: $stdout, err: $stderr)
  end

  def guard_ok?(values)
    return false if values[:only_if] && !system("/bin/sh", "-c", retarget(values[:only_if]), out: File::NULL, err: File::NULL)
    return false if values[:not_if] && system("/bin/sh", "-c", retarget(values[:not_if]), out: File::NULL, err: File::NULL)

    true
  end

  def run
    instance_eval("def evaluate_recipe\n#{File.read(@path)}\nend", @path, 0)
    evaluate_recipe
    delayed = []
    @resources.each do |kind, name, v|
      label = "#{kind}[#{name.sub(@home, '~')}]"
      as = " as #{v[:user] || v[:owner]}"
      if kind == :execute && v[:action] == :nothing
        next
      end
      unless guard_ok?(v)
        puts "RESOURCE #{label} skipped#{as}"
        next
      end
      case kind
      when :directory
        FileUtils.mkdir_p(name)
        File.chmod(v[:mode].to_i(8), name)
        puts "RESOURCE #{label} ensured#{as}"
      when :remote_file
        src = File.join(File.dirname(@path), v[:source])
        if File.file?(name) && File.read(name) == File.read(src)
          puts "RESOURCE #{label} unchanged#{as}"
          next
        end
        FileUtils.cp(src, name)
        File.chmod(v[:mode].to_i(8), name)
        puts "RESOURCE #{label} changed#{as}"
        delayed << v[:notifies] if v[:notifies]
      when :execute
        raise "resource failed: #{name}" unless sh(v[:command])

        puts "RESOURCE #{label} ran#{as}"
        delayed << v[:notifies] if v[:notifies]
      end
    end
    delayed.uniq.each do |target|
      name = target[/\Aexecute\[(.*)\]\z/, 1]
      _, _, v = @resources.find { |kind, n, _| kind == :execute && n == name } || raise("unknown notify target #{target}")
      raise "resource failed: #{name}" unless sh(v[:command])

      puts "RESOURCE execute[#{name}] ran (notified) as #{v[:user]}"
    end
  end
end

RemoteControlFixture.new(File.expand_path(ARGV.fetch(0)), File.expand_path(ARGV.fetch(1))).run
