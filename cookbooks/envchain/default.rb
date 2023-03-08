case node[:platform]
when 'darwin'
  package 'envchain'
when 'arch'
  include_cookbook 'arch-wanko-cc'
  package 'envchain'
when 'ubuntu'
  include_cookbook 'apt-source-cookpad'
  package 'envchain'
else
  raise NotImplementedError
end
