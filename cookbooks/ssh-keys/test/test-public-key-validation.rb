# frozen_string_literal: true
#
# Evaluates cookbooks/ssh-keys/default.rb (unmodified) under CRuby through a
# stub mitamae DSL: `aws ssm get-parameter` answers from an in-memory fixture
# registry, `hostname -s` answers "host-a", and resources are recorded instead
# of run. No AWS, no network, nothing outside a fresh fixture HOME is touched.
#
# What this protects: every SSM `<ssm_prefix>/public` value is written into the
# authorized_keys managed block of EVERY fleet host. Only a value that is
# exactly one public key line may get there. The placeholder an ios-client
# slot holds before its key is uploaded, a line with authorized_keys options,
# a multi-line value and a private key must be skipped with a warning naming
# the SSM path (and never the value). Valid keys — rsa, no comment, shared
# twin keys whose comments are merged — must come out exactly as before.
#
# Positive control: the same cases run against a mutant of the recipe with the
# single-line check removed. The mutant MUST fail at least one skip case; if it
# passes everything, this harness cannot see the check and the run FAILS.
#
# Usage: ruby test-public-key-validation.rb [RECIPE]
#   RECIPE defaults to ../default.rb. Passing another recipe (e.g. the version
#   before the check) runs the cases only, without the positive control.
# Exit 0 when every assertion passes. One PASS/FAIL line per assertion.
require "json"
require "tmpdir"

HERE = File.expand_path(__dir__)
DEFAULT_RECIPE = File.join(HERE, "..", "default.rb")

ED = "AAAAC3NzaC1lZDI1NTE5AAAAIFixtureEd25519KeyOnlyForTestsAAAAAAAAAAAA"
ED2 = "AAAAC3NzaC1lZDI1NTE5AAAAIFixtureEd25519SecondKeyForTestsBBBBBBBBBB"
TWIN = "AAAAC3NzaC1lZDI1NTE5AAAAIFixtureTwinKeySharedByTwoDevicesCCCCCCCC"
TWINC = "AAAAC3NzaC1lZDI1NTE5AAAAIFixtureTwinKeyWithCommentDDDDDDDDDDDDDDDD"
RSA = "AAAAB3NzaC1yc2EAAAADAQABAAABAQFixtureRsaKeyOnlyForTests+/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=="
ECDSA = "AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBBFixtureEcdsa="
SK = "AAAAGnNrLXNzaC1lZDI1NTE5QG9wZW5zc2guY29tAAAAIFixtureSkKey"

# [device, public value as SSM returns it (fetch_ssm strips it), keep?]
CASES = [
  ["ed25519-comment", "ssh-ed25519 #{ED} sh1@air", true],
  ["rsa-comment", "ssh-rsa #{RSA} sh1@mini", true],
  ["ecdsa-no-comment", "ecdsa-sha2-nistp256 #{ECDSA}", true],
  ["sk-key", "sk-ssh-ed25519@openssh.com #{SK} yubikey", true],
  ["comment-spaces", "ssh-ed25519 #{ED2} shin ohno on pro", true],
  ["twin-a", "ssh-ed25519 #{TWIN}", true],
  ["twin-b", "ssh-ed25519 #{TWIN}", true],
  ["twinc-a", "ssh-ed25519 #{TWINC} sh1@pro", true],
  ["twinc-b", "ssh-ed25519 #{TWINC} sh1@pro", true],
  ["ipad-yebisu", "placeholder — upload real public key with scripts/register_ios_key.sh", false],
  ["ipad", "placeholder — upload real public key via AWS Console", false],
  ["opt-command", "command=\"/bin/sh -c id\" ssh-ed25519 #{ED} evil", false],
  ["opt-from", "from=\"10.0.0.0/8\",no-pty ssh-ed25519 #{ED}", false],
  ["opt-restrict", "restrict ssh-ed25519 #{ED}", false],
  ["two-lines", "ssh-ed25519 #{ED} a\nssh-ed25519 #{ED2} b", false],
  ["cr-in-value", "ssh-ed25519 #{ED} a\rssh-ed25519 #{ED2} b", false],
  ["tab-in-comment", "ssh-ed25519 #{ED} a\tb", false],
  ["esc-in-comment", "ssh-ed25519 #{ED} a\e[31mb", false],
  ["private-key", "-----BEGIN OPENSSH PRIVATE KEY-----\nb3BlbnNzaC1rZXktdjEAAAAABG5vbmU=\n-----END OPENSSH PRIVATE KEY-----", false],
  ["dss", "ssh-dss AAAAB3NzaC1kc3MAAACBAFixture", false],
  ["bad-blob", "ssh-ed25519 AAAA$(id) x", false],
  ["empty", "", false],
].freeze

# The managed block the recipe wrote before the check existed, for the keep
# cases (same order as CASES): unchanged lines, a device name appended where
# there is no comment, and twin keys merged into one line.
EXPECTED_BLOCK = [
  "# BEGIN ssh-keys-managed",
  "ssh-ed25519 #{ED} sh1@air",
  "ssh-rsa #{RSA} sh1@mini",
  "ecdsa-sha2-nistp256 #{ECDSA} ecdsa-no-comment",
  "sk-ssh-ed25519@openssh.com #{SK} yubikey",
  "ssh-ed25519 #{ED2} shin ohno on pro",
  "ssh-ed25519 #{TWIN} twin-a,twin-b",
  "ssh-ed25519 #{TWINC} sh1@pro,twinc-b",
  "# END ssh-keys-managed",
].freeze

module MItamae
  @messages = []
  class << self
    attr_reader :messages

    def logger
      log = Object.new
      msgs = @messages
      %i[info warn].each { |level| log.define_singleton_method(level) { |m| msgs << [level, m] } }
      log
    end
  end
end

# Records a resource block's attributes (content, command, owner, ...).
class ResourceRecorder
  attr_reader :attrs

  def initialize
    @attrs = {}
  end

  def method_missing(name, *args)
    @attrs[name] = args.first
  end

  def respond_to_missing?(*)
    true
  end
end

# The stub DSL the recipe is instance_eval'ed in.
class RecipeFixture
  Result = Struct.new(:stdout, :exit_status)

  attr_reader :node, :files

  def initialize(home, ssm)
    @ssm = ssm
    @files = {}
    @node = { setup: { user: "fixture", group: "fixture", home: home, root: "#{home}/.setup" } }
  end

  def include_platform_cookbook(_name); end

  def require_external_auth(**_opts); end

  def run_command(command, **_opts)
    return Result.new("host-a\n", 0) if command == "hostname -s"

    name = command[/--name '([^']+)'/, 1]
    raise "unexpected command: #{command}" unless command.start_with?("aws ssm get-parameter") && name
    return Result.new("", 255) unless @ssm.key?(name)

    Result.new("#{@ssm[name]}\n", 0)
  end

  def directory(_path, &block)
    ResourceRecorder.new.instance_eval(&block)
  end

  def execute(_name, &block)
    ResourceRecorder.new.instance_eval(&block)
  end

  def file(path, &block)
    rec = ResourceRecorder.new
    rec.instance_eval(&block)
    @files[path] = rec.attrs[:content]
  end
end

def registry_for(cases)
  devices = { "host-a" => { "ssh" => { "ssm_prefix" => "/ssh-keys/devices/host-a", "key_file" => "host_a_ed25519",
                                       "user" => "fixture" } } }
  ssm = {}
  cases.each do |device, value, _keep|
    devices[device] = { "client_only" => true, "ssh" => { "ssm_prefix" => "/ssh-keys/devices/#{device}" } }
    ssm["/ssh-keys/devices/#{device}/public"] = value
  end
  ssm["/host-registry/devices"] = JSON.generate("devices" => devices)
  ssm
end

# Evaluates the recipe source with __FILE__ = the real recipe path (so
# files/aws-config.json resolves) and returns [managed block lines, warnings].
def render(source, recipe_path, cases)
  MItamae.messages.clear
  Dir.mktmpdir("ssh-keys-test-") do |home|
    fixture = RecipeFixture.new(home, registry_for(cases))
    fixture.instance_eval(source, recipe_path)
    content = fixture.files["#{home}/.ssh/authorized_keys"]
    lines = content ? content.lines.map(&:chomp) : []
    first = lines.index("# BEGIN ssh-keys-managed")
    last = lines.index("# END ssh-keys-managed")
    block = first && last ? lines[first..last] : []
    warnings = MItamae.messages.select { |level, _| level == :warn }.map { |_, m| m }
    return [block, warnings]
  end
end

# Runs every assertion against one recipe source; returns the failure count.
def run_cases(label, source, recipe_path, quiet: false)
  failures = 0
  say = lambda do |ok, msg|
    failures += 1 unless ok
    puts "#{ok ? 'PASS' : 'FAIL'}  [#{label}] #{msg}" unless quiet
  end

  block, warnings = render(source, recipe_path, CASES)
  say.call(block == EXPECTED_BLOCK,
           "managed block holds exactly the keep cases, unchanged" +
             (block == EXPECTED_BLOCK ? "" : " (got #{block.inspect})"))

  # The keep cases alone: what the recipe wrote before the check (run this
  # file against that version to see this line pass there too).
  keep_block, keep_warnings = render(source, recipe_path, CASES.select { |c| c[2] })
  # (host-a has no fixture keys, so "failed to fetch" warnings for it are expected.)
  keep_warnings = keep_warnings.reject { |w| w.include?("/ssh-keys/devices/host-a/") }
  say.call(keep_block == EXPECTED_BLOCK && keep_warnings.empty?,
           "keep cases alone give the same managed block, no warning" +
             (keep_block == EXPECTED_BLOCK ? "" : " (got #{keep_block.inspect})"))

  CASES.each do |device, value, keep|
    path = "/ssh-keys/devices/#{device}/public"
    warned = warnings.any? { |w| w.include?(path) }
    if keep
      say.call(!warned, "keep #{device}: no warning")
    else
      say.call(warned, "skip #{device}: warning names #{path}")
      lines_with_value = value.empty? ? [] : value.split(/[\r\n]/).reject(&:empty?)
      leaked = lines_with_value.any? { |l| block.any? { |b| b.include?(l) } }
      say.call(!leaked, "skip #{device}: value not in managed block")
      say.call(warnings.none? { |w| !value.empty? && w.include?(value) }, "skip #{device}: warning does not print the value")
    end

    # Alone (a registry holding only this device) — the twin merge needs both.
    next if device.start_with?("twin")

    solo_block, = render(source, recipe_path, [[device, value, keep]])
    expected = keep ? 3 : 0
    say.call(solo_block.length == expected,
             "alone #{device}: #{keep ? 'one key line' : 'no managed block written'}" +
               (solo_block.length == expected ? "" : " (got #{solo_block.inspect})"))
  end
  failures
end

recipe = File.expand_path(ARGV[0] || DEFAULT_RECIPE)
source = File.read(recipe)
failures = run_cases("recipe", source, recipe)

if recipe == File.expand_path(DEFAULT_RECIPE)
  # Positive control: drop the single-line check and expect the cases to fail.
  mutant = source.sub(/^  unless pub_line =~ PUBLIC_KEY_LINE\n.*?^    next\n  end\n/m, "")
  if mutant == source
    failures += 1
    puts "FAIL  [positive-control] could not remove the check from #{recipe} (pattern drifted)"
  else
    mutant_failures = run_cases("mutant", mutant, recipe, quiet: true)
    ok = mutant_failures.positive?
    failures += 1 unless ok
    puts "#{ok ? 'PASS' : 'FAIL'}  [positive-control] recipe without the check fails #{mutant_failures} assertion(s)"
  end
end

puts(failures.positive? ? "FAILED: #{failures}" : "OK")
exit(failures.positive? ? 1 : 0)
