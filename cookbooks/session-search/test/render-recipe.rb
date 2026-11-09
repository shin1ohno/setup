# frozen_string_literal: true
# Execute the real cookbook's placement/launcher resources inside a fixture HOME.
require "fileutils"
require "open3"

module MItamae
  def self.logger
    Object.new.tap do |logger|
      %i[info warn].each { |level| logger.define_singleton_method(level) { |message| puts "#{level}: #{message}" } }
    end
  end
end

class RecipeFixture
  Result = Struct.new(:stdout, :exit_status)
  def initialize(path, home)
    raise "fixture marker required" unless File.file?("#{home}/.fixture-home")
    @path, @home, @resources = path, home, []
    @node = { profile: { label: "air", hostname: "fixture" },
              hw: { machine: RUBY_PLATFORM.include?("arm64") || RUBY_PLATFORM.include?("aarch64") ? "aarch64" : "x86_64" },
              setup: { user: ENV.fetch("USER", "runner"), group: "fixture", home: home } }
    @node.define_singleton_method(:reverse_merge!) { |value| merge!(value) }
  end
  attr_reader :node
  def platform_value(darwin:, linux:)
    RUBY_PLATFORM.include?("darwin") ? darwin : linux
  end
  def run_command(command, **_options)
    return Result.new("1000\n", 0) if command == "id -u"

    out, err, status = Open3.capture3("/bin/sh", "-c", command)
    warn err unless err.empty?
    Result.new(out, status.exitstatus)
  end
  %i[directory remote_file execute file local_ruby_block].each do |kind|
    define_method(kind) do |name, &block|
      values = {}
      resource = Object.new
      %i[owner group mode only_if not_if source command content user block].each do |field|
        resource.define_singleton_method(field) { |value = nil, &body| values[field] = body || value }
      end
      resource.instance_eval(&block)
      @resources << [kind, name, values]
    end
  end
  def run
    instance_eval("def evaluate_recipe\n#{File.read(@path)}\nend", @path, 0)
    evaluate_recipe
    puts "ENGINE #{node[:session_search][:engine]}"
    @resources.each do |kind, name, v|
      next if v[:only_if] && !system("/bin/sh", "-c", v[:only_if], out: File::NULL, err: File::NULL)
      next if v[:not_if] && system("/bin/sh", "-c", v[:not_if], out: File::NULL, err: File::NULL)

      case kind
      when :directory then FileUtils.mkdir_p(name)
      when :remote_file then FileUtils.cp(File.join(File.dirname(@path), v[:source]), name)
      when :file then File.write(name, v[:content])
      when :execute
        raise "resource failed: #{name}" unless system("/bin/sh", "-c", v[:command])
      when :local_ruby_block then v[:block].call
      end
      File.chmod(v[:mode].to_i(8), name) if v[:mode] && File.exist?(name)
    end
  end
end

RecipeFixture.new(File.expand_path(ARGV.fetch(0)), File.expand_path(ARGV.fetch(1))).run
