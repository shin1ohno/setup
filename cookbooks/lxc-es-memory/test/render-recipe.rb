# frozen_string_literal: true

# Evaluate cookbooks/lxc-es-memory/default.rb against a recording stand-in for
# the mitamae DSL and print every declared resource with its attributes, one
# JSON object per line, in declaration order. Nothing is executed: guards,
# commands and require_external_auth blocks are recorded, not run.
#
# Usage: ruby render-recipe.rb <recipe> [<files dir>]
# The optional files dir replaces the recipe's own files/ for the pin reads, so a
# test can try a pin without editing the tree.
require "json"

class RecordingResource
  attr_reader :attrs

  def initialize(node)
    @node = node
    @attrs = {}
  end

  attr_reader :node

  def method_missing(name, *args, &block)
    value = block ? "<block>" : (args.length == 1 ? args.first : args)
    if name == :notifies
      (@attrs[:notifies] ||= []) << args
    else
      @attrs[name] = value
    end
    nil
  end

  def respond_to_missing?(*)
    true
  end
end

class RecipeRenderer
  Node = Struct.new(:data) do
    def [](key)
      data[key]
    end
  end

  def initialize(recipe, files_dir)
    @recipe = recipe
    @files_dir = files_dir
    @resources = []
    @node = { setup: { root: "/root/setup-root", user: "fixture", group: "fixture" } }
  end

  attr_reader :node, :resources

  def include_cookbook(name)
    @resources << { type: "include_cookbook", name: name }
  end

  %i[execute directory remote_file file systemd_unit].each do |type|
    define_method(type) do |name, &block|
      resource = RecordingResource.new(@node)
      resource.instance_eval(&block) if block
      @resources << { type: type.to_s, name: name, attrs: resource.attrs }
    end
  end

  def require_external_auth(**options)
    @resources << { type: "require_external_auth", name: options[:tool_name],
                    skip_if: options.key?(:skip_if) ? "<lambda>" : nil }
    yield
  end

  def render
    source = File.read(@recipe)
    if @files_dir
      # Only the pin reads are redirected; every other path is untouched.
      pin_dir = File.expand_path(@files_dir).inspect
      source = source.gsub('File.join(File.dirname(__FILE__), "files", "ai-memory.pin")', "File.join(#{pin_dir}, \"ai-memory.pin\")")
                     .gsub('File.join(File.dirname(__FILE__), "files", "ai-memory-bin.pin")', "File.join(#{pin_dir}, \"ai-memory-bin.pin\")")
    end
    instance_eval(source, @recipe, 1)
    @resources.each { |r| puts JSON.generate(r) }
  end
end

RecipeRenderer.new(File.expand_path(ARGV.fetch(0)), ARGV[1]).render
