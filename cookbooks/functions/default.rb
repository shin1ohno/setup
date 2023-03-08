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
end
MItamae::RecipeContext.send(:include, RecipeHelper)

define :install_package, darwin: nil, ubuntu: nil, arch: nil do
  pkgs = params[node[:platform].to_sym]
  if pkgs
    Array(pkgs).each do |pkg|
      package pkg
    end
  else
    raise "Unsupported platform #{node[:platform]}"
  end
end

define :add_profile, bash_content: nil, fish_content: nil, priority: 50 do
  bash_content = params[:bash_content]

  unless bash_content
    raise 'add_profile requires bash_content'
  end

  priority = params[:priority]
  name = params[:name]

  file "#{node[:setup][:root]}/profile.d/#{priority}-#{name}.sh" do
    owner node[:setup][:user]
    group node[:setup][:group]
    mode '644'
    content bash_content
  end

  if ENV['CPAD2_ENABLE_FISH'] == '1'
    fish_content = params[:fish_content]

    unless fish_content
      raise 'add_profile requires fish_content'
    end

    file "#{node[:setup][:root]}/profile.d/#{priority}-#{name}.fish" do
      owner node[:setup][:user]
      group node[:setup][:group]
      mode '644'
      content fish_content
    end
  end
end
