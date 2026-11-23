# frozen_string_literal: true
#
# Evaluates cookbooks/ssh-keys/default.rb (unmodified) under CRuby through a
# stub mitamae DSL: `aws ssm get-parameter --output text` answers from an
# in-memory fixture registry exactly as the CLI prints it (the stored value
# plus one newline), `hostname -s` answers "host-a", and resources are
# recorded instead of run. No AWS, no network, nothing outside a fresh fixture
# HOME is touched. The key blobs are public halves of throwaway keys made with
# ssh-keygen for this test (sk-* blobs are assembled from them below).
#
# What this protects: every SSM `<ssm_prefix>/public` value is written into the
# authorized_keys managed block of EVERY fleet host. Only a value that is
# exactly one real public key line may get there; everything else is skipped
# with a warning naming the SSM path (never the value). Valid keys — rsa, no
# comment, tab or several blanks between fields, twin keys whose comments are
# merged — must come out exactly as before. Both authorized_keys file
# resources (the normal file and the PVE pmxcfs staging file) must be
# `sensitive`, so the old content never reaches mitamae's diff log.
#
# Positive controls: the cases also run against two mutants of the recipe —
# one with the check replaced by the old `strip`, one without `sensitive` on
# the authorized_keys files. Each mutant MUST fail; if one passes, this
# harness cannot see what it claims to test and the run FAILS.
#
# Usage: ruby test-public-key-validation.rb [RECIPE]
#   RECIPE defaults to ../default.rb. Passing another recipe (e.g. an older
#   version) runs the cases only, without the positive controls.
# Exit 0 when every assertion passes. One PASS/FAIL line per assertion.
require "json"
require "tmpdir"

HERE = File.expand_path(__dir__)
DEFAULT_RECIPE = File.join(HERE, "..", "default.rb")

ED1 = "AAAAC3NzaC1lZDI1NTE5AAAAIFxhOdrHAupeHffCSHSjEEkFo/AVIMFPbIqo0wasadJx"
ED2 = "AAAAC3NzaC1lZDI1NTE5AAAAIFOoWZ21UyTetEmbO9IluBZR2HBGghMnI1hsEL26k5WD"
ED3 = "AAAAC3NzaC1lZDI1NTE5AAAAIEXQV4iPm7iyC3HPs0YhZRdcBTNnITr3vXUOO41PNpXO"
ED4 = "AAAAC3NzaC1lZDI1NTE5AAAAIHH7WOsDIRYOokXKw8hITsDlZS/siUpVW7j4vMNxFiVp"
ED5 = "AAAAC3NzaC1lZDI1NTE5AAAAIA3trirTVFWKHDViNQpDJ+EiPHF3UcWE0hWWr9NcOLSu"
ED6 = "AAAAC3NzaC1lZDI1NTE5AAAAIALiHfoJeiMbu68XEphwuO2Yjn0TuTmxiboUi59z+iho"
ED7 = "AAAAC3NzaC1lZDI1NTE5AAAAICa02ouLcHqq5uEZ6jXEL9EVnPSC5iW0yTfbWNo7DaC3"
ED8 = "AAAAC3NzaC1lZDI1NTE5AAAAIF1vNv/kNG3mdt2ZItV8IuNB6RLb04PvTEsvqO0gzD/B"
ED9 = "AAAAC3NzaC1lZDI1NTE5AAAAIAgPfWpL6O2GPCX7/a+OnR0xqK6gf3gNmw/p4pqgBp6C"
ED10 = "AAAAC3NzaC1lZDI1NTE5AAAAIO6+MJWcHEymzQitcTnq/LWqIr6AaUBhqaLj+YzL0qcL"
ED11 = "AAAAC3NzaC1lZDI1NTE5AAAAIPwLEzUvrNtwOfhRsi2AzyqUddRH/hEo4wPpzrzVjKX1"
ED12 = "AAAAC3NzaC1lZDI1NTE5AAAAIB3yP42/PeTbMYyuQFBMbXsTb5lKXfwuB00Rjlpv2BFZ"
ED13 = "AAAAC3NzaC1lZDI1NTE5AAAAIBGL7YFu/7KXBf/mT+bdId9naiWDkNz7H5zRiGMlz47G"
ED14 = "AAAAC3NzaC1lZDI1NTE5AAAAILL0LYvg6Po9T5jwzeemX/nqLECd2EPp2qWoyqyr7xPk"
RSA2048 = "AAAAB3NzaC1yc2EAAAADAQABAAABAQDMmkbXs2071rn7sf1ebBy6zdRDi0Guaq70Tx759IehxmOYOV2mk1bxhSkdea6Snh0/" \
          "4XUziYgY9RwVtuyuYW34SEt6ad1L7opbd++SjlxEaDxiCIePIngm6aKn1T6t+u7RuRYi04JqfUXSgL33KsfByPBEZzVZbj3e" \
          "zuD5P6wkydTWX8j0hkl6WIzFZEKEM0Rj9fP9EHLootQUYA4rqQcx6BOsJHulS9fApfD73SsiGzjljTWmwE1ZEElVZsBvphOZ" \
          "YWrZzzBIWBYZh8nf81S6sKZaryJPKsvoUq+VFf/CJlNbZtg/4GFq3DwXfDGuJnSq6cZBKac0ECxbqCH8Mmtl"
RSA1024 = "AAAAB3NzaC1yc2EAAAADAQABAAAAgQCo1MEqsUkraIZyMHPzK8Odv7l2LXEAu8MjnJh9da71lS5+y81bSULgnPWEty14NURY" \
          "3x3Qslvb4XhVIVPl+HmfQVuBHbqnH66cHB4LwzvHWi0Pq8qc+Tq/HGmXV828A8cUP17EihM0oeiwuwZuT6cw21Pnlmp8TO0U" \
          "OtvryZyVKQ=="
EC256 = "AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBBOh8+0F8cEssvCLbNc+6SyJx7YHXtu9LIv7rsdFefsM0" \
        "EujG6sLSegLnCd4LOWvl4HPbmH23N9iwcQAn+JFFY3Y="
EC384 = "AAAAE2VjZHNhLXNoYTItbmlzdHAzODQAAAAIbmlzdHAzODQAAABhBFFQDmfMyvGLVlEFu5bEMpBEnauLO/HxOui2RiOySpnp" \
        "WyFUbiRlTHIP1gZEG7SteoobbZP433t2UhSxUZU/Y+eXFvmwl3gNi0onJUIUAvk9cJdYo7qiRi3/zi3UN6pLJw=="
EC521 = "AAAAE2VjZHNhLXNoYTItbmlzdHA1MjEAAAAIbmlzdHA1MjEAAACFBAG5P94XaIertFRLUzqUodQstEVTKq+fxR/ZmN+uxrQ8" \
        "eqiHpnWXifm3QsabJJfqCsfSHlZ5fBKnGs4b9y5esFACIQHC/NJDZ4YLGPuCV7x8itp3svfEqZ1akJkC/e8PymuHJ0WoKgxt" \
        "3Fg+9Sa6/hzFTseIlryqQSvCXD26KP4vCWwncg=="

def b64(bytes) = [bytes].pack("m0")
def unb64(text) = text.unpack1("m0")
def wire(str) = [str.bytesize].pack("N") + str.b

# Wire fields of a blob: ["ssh-ed25519", <pk>] etc.
def fields_of(blob)
  data = unb64(blob)
  out = []
  until data.empty?
    len = data[0, 4].unpack1("N")
    out << data[4, len]
    data = data[4 + len..]
  end
  out
end

ED7_PK = fields_of(ED7)[1]
EC256_POINT = fields_of(EC256)[2]
SK_ED = b64(wire("sk-ssh-ed25519@openssh.com") + wire(ED7_PK) + wire("ssh:"))
SK_EC = b64(wire("sk-ecdsa-sha2-nistp256@openssh.com") + wire("nistp256") + wire(EC256_POINT) + wire("ssh:"))
RSA512 = b64(wire("ssh-rsa") + wire("\x01\x00\x01".b) + wire("\x00\xC0".b + ("\x11".b * 63)))
ED_TRUNCATED = b64(unb64(ED1)[0, 30])
ED_TRAILING = b64(unb64(ED1) + "\x00".b)
ED_SHORT_PK = b64(wire("ssh-ed25519") + wire("\x01".b * 31))
EC256_BAD_SLOP = EC256.sub(/Y3Y=\z/, "Y3Z=") # same length, non-zero bits after the last byte
EC256_NO_PAD = EC256.chomp("=")
EC256_COMPRESSED = b64(wire("ecdsa-sha2-nistp256") + wire("nistp256") + wire("\x02".b + EC256_POINT[1, 32]))
SK_NO_APP = b64(wire("sk-ssh-ed25519@openssh.com") + wire(ED7_PK))

MAX_LINE = 4096
LONG_PREFIX = "ssh-ed25519 #{ED13} "

# [device, value as stored in SSM, keep?]
CASES = [
  ["ed25519-comment", "ssh-ed25519 #{ED1} sh1@air", true],
  ["rsa-comment", "ssh-rsa #{RSA2048} sh1@mini", true],
  ["rsa1024-no-comment", "ssh-rsa #{RSA1024}", true],
  ["ecdsa-no-comment", "ecdsa-sha2-nistp256 #{EC256}", true],
  ["ecdsa384", "ecdsa-sha2-nistp384 #{EC384} p384", true],
  ["ecdsa521", "ecdsa-sha2-nistp521 #{EC521} p521", true],
  ["sk-ed25519", "sk-ssh-ed25519@openssh.com #{SK_ED} yubikey", true],
  ["sk-ecdsa", "sk-ecdsa-sha2-nistp256@openssh.com #{SK_EC} yubikey-ec", true],
  ["comment-spaces", "ssh-ed25519 #{ED2} shin ohno on pro", true],
  ["tab-separator", "ssh-ed25519\t#{ED5}\tsh1@tab", true],
  ["several-blanks", "ssh-ed25519   #{ED6}  \t sh1@blanks", true],
  ["tab-in-comment", "ssh-ed25519 #{ED8} a\tb", true],
  ["trailing-lf", "ssh-ed25519 #{ED9} stored-with-lf\n", true],
  ["trailing-crlf", "ssh-ed25519 #{ED10} stored-with-crlf\r\n", true],
  ["surrounding-blanks", "  ssh-ed25519 #{ED11} padded \t ", true],
  ["unicode-comment", "ssh-ed25519 #{ED12} 大野 — air", true],
  ["max-length", LONG_PREFIX + ("c" * (MAX_LINE - LONG_PREFIX.bytesize)), true],
  ["twin-a", "ssh-ed25519 #{ED3}", true],
  ["twin-b", "ssh-ed25519 #{ED3}", true],
  ["twinc-a", "ssh-ed25519 #{ED4} sh1@pro", true],
  ["twinc-b", "ssh-ed25519 #{ED4} sh1@pro", true],
  # --- policy: not one public key line ---
  ["ipad-yebisu", "placeholder — upload real public key with scripts/register_ios_key.sh", false],
  ["ipad", "placeholder — upload real public key via AWS Console", false],
  ["opt-command", "command=\"/bin/sh -c id\" ssh-ed25519 #{ED1} evil", false],
  ["opt-from", "from=\"10.0.0.0/8\",no-pty ssh-ed25519 #{ED1}", false],
  ["opt-restrict", "restrict ssh-ed25519 #{ED1}", false],
  ["two-lines", "ssh-ed25519 #{ED1} a\nssh-ed25519 #{ED2} b", false],
  ["private-key", "-----BEGIN OPENSSH PRIVATE KEY-----\nb3BlbnNzaC1rZXktdjEAAAAABG5vbmU=\n-----END OPENSSH PRIVATE KEY-----", false],
  ["dss", "ssh-dss AAAAB3NzaC1kc3MAAACBAFixture dss", false],
  ["empty", "", false],
  ["only-newline", "\n", false],
  # --- raw value: line structure and control characters ---
  ["leading-blank-line", "\nssh-ed25519 #{ED14} x", false],
  ["trailing-blank-line", "ssh-ed25519 #{ED14} x\n\n", false],
  ["trailing-blank-crlf", "ssh-ed25519 #{ED14} x\r\n\r\n", false],
  ["cr-inside", "ssh-ed25519 #{ED14} a\rb", false],
  ["cr-before-space", "ssh-ed25519 #{ED14}\r x", false],
  ["lone-trailing-cr", "ssh-ed25519 #{ED14} x\r", false],
  ["trailing-nul", "ssh-ed25519 #{ED14} x\u0000", false],
  ["nul-in-comment", "ssh-ed25519 #{ED14} a\u0000b", false],
  ["esc-in-comment", "ssh-ed25519 #{ED14} a\e[31mb", false],
  ["del-in-comment", "ssh-ed25519 #{ED14} a\u007Fb", false],
  ["u0085-in-comment", "ssh-ed25519 #{ED14} a\u0085b", false],
  ["u009b-in-comment", "ssh-ed25519 #{ED14} a\u009B31mb", false],
  ["u2028-in-comment", "ssh-ed25519 #{ED14} a b", false],
  # --- length ---
  ["over-max-length", LONG_PREFIX + ("c" * (MAX_LINE + 1 - LONG_PREFIX.bytesize)), false],
  ["comment-8kib", "ssh-ed25519 #{ED14} #{'c' * 8192}", false],
  # --- the blob is not a real key of the declared type ---
  ["short-valid-base64", "ssh-ed25519 dGVzdA== x", false],
  ["truncated-blob", "ssh-ed25519 #{ED_TRUNCATED} x", false],
  ["trailing-data", "ssh-ed25519 #{ED_TRAILING} x", false],
  ["ed25519-31-bytes", "ssh-ed25519 #{ED_SHORT_PK} x", false],
  ["type-mismatch", "ssh-rsa #{ED14} x", false],
  ["curve-mismatch", "ecdsa-sha2-nistp384 #{EC256} x", false],
  ["bad-padding-bits", "ecdsa-sha2-nistp256 #{EC256_BAD_SLOP} x", false],
  ["missing-padding", "ecdsa-sha2-nistp256 #{EC256_NO_PAD} x", false],
  ["extra-padding", "ecdsa-sha2-nistp256 #{EC256}= x", false],
  ["padding-inside", "ssh-ed25519 #{ED14[0, 8]}=#{ED14[9..]} x", false],
  ["compressed-point", "ecdsa-sha2-nistp256 #{EC256_COMPRESSED} x", false],
  ["rsa-512-bits", "ssh-rsa #{RSA512} x", false],
  ["sk-no-application", "sk-ssh-ed25519@openssh.com #{SK_NO_APP} x", false],
  ["bad-blob-chars", "ssh-ed25519 AAAA$(id) x", false],
].freeze

# The line the recipe wrote before the check for a value it keeps: the value
# stripped, plus the device name when it has no comment.
def today_line(device, value)
  line = value.strip
  line.split(/\s+/).length < 3 ? "#{line} #{device}" : line
end

EXPECTED_BLOCK = (["# BEGIN ssh-keys-managed"] +
  CASES.select { |c| c[2] }.reject { |c| %w[twin-b twinc-b].include?(c[0]) }.map do |device, value, _|
    case device
    when "twin-a" then "ssh-ed25519 #{ED3} twin-a,twin-b"
    when "twinc-a" then "ssh-ed25519 #{ED4} sh1@pro,twinc-b"
    else today_line(device, value)
    end
  end + ["# END ssh-keys-managed"]).freeze

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

# Records a resource block's attributes (content, command, sensitive, ...).
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

  # The recipe's `File` resolves here (constant lookup goes through the
  # fixture's ancestors before Object), so a test can make authorized_keys a
  # symlink into /etc/pve without touching the real /etc/pve.
  class File < ::File
    class << self
      attr_accessor :pve_link

      def symlink?(path) = (pve_link && path == pve_link) || super
      def realpath(path, *rest) = pve_link && path == pve_link ? "/etc/pve/priv/authorized_keys" : super
      def exist?(path) = path.start_with?("/etc/pve/") ? false : super
    end
  end

  attr_reader :node, :files

  def initialize(home, ssm)
    @ssm = ssm
    @files = {}
    @node = { setup: { user: "fixture", group: "fixture", home: home, root: "#{home}/.setup" } }
  end

  def include_platform_cookbook(_name); end

  def require_external_auth(**_opts); end

  # Answers like `aws ssm get-parameter --output text`: the value + "\n".
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
    @files[path] = rec.attrs
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

def managed_block(content)
  lines = content ? content.lines.map(&:chomp) : []
  first = lines.index("# BEGIN ssh-keys-managed")
  last = lines.index("# END ssh-keys-managed")
  first && last ? lines[first..last] : []
end

# Evaluates the recipe source with __FILE__ = the real recipe path (so
# files/aws-config.json resolves). Returns a Hash: :block (managed block of
# the file written), :content, :warnings, :files, :home.
def render(source, recipe_path, cases, existing: nil, pve: false)
  MItamae.messages.clear
  Dir.mktmpdir("ssh-keys-test-") do |home|
    auth = "#{home}/.ssh/authorized_keys"
    if existing
      Dir.mkdir("#{home}/.ssh")
      File.write(auth, existing)
    end
    RecipeFixture::File.pve_link = pve ? auth : nil
    fixture = RecipeFixture.new(home, registry_for(cases))
    fixture.instance_eval(source, recipe_path)
    RecipeFixture::File.pve_link = nil
    target = pve ? "#{home}/.setup/ssh-keys/authorized_keys.staged" : auth
    written = fixture.files[target]
    warnings = MItamae.messages.select { |level, _| level == :warn }.map { |_, m| m }
                      .reject { |w| w.include?("/ssh-keys/devices/host-a/") } # host-a has no fixture keys
    return { block: managed_block(written && written[:content]), content: written && written[:content],
             written: written, warnings: warnings }
  end
end

# Runs every assertion against one recipe source; returns the failure count.
def run_cases(label, source, recipe_path, quiet: false)
  failures = 0
  say = lambda do |ok, msg|
    failures += 1 unless ok
    puts "#{ok ? 'PASS' : 'FAIL'}  [#{label}] #{msg}" unless quiet
  end
  shown = ->(a, b) { a == b ? "" : " (got #{a.inspect[0, 400]})" }

  all = render(source, recipe_path, CASES)
  say.call(all[:block] == EXPECTED_BLOCK, "all cases: managed block holds exactly the keep cases, unchanged" +
           shown.call(all[:block], EXPECTED_BLOCK))

  keep_only = render(source, recipe_path, CASES.select { |c| c[2] })
  say.call(keep_only[:block] == EXPECTED_BLOCK && keep_only[:warnings].empty?,
           "keep cases alone: same managed block, no warning" + shown.call(keep_only[:block], EXPECTED_BLOCK))

  CASES.each do |device, value, keep|
    path = "/ssh-keys/devices/#{device}/public"
    warned = all[:warnings].any? { |w| w.include?(path) }
    if keep
      say.call(!warned, "keep #{device}: no warning")
    else
      say.call(warned, "skip #{device}: warning names #{path}")
      # Pieces of the value long enough to identify it (not a 1-char tail).
      pieces = value.split(/[\r\n\u0000]/).map(&:strip).select { |piece| piece.length > 12 }
      leaked = pieces.any? { |piece| all[:block].any? { |b| b.include?(piece) } }
      say.call(!leaked, "skip #{device}: value not in managed block")
      say.call(all[:warnings].none? { |w| pieces.any? { |piece| w.include?(piece) } },
               "skip #{device}: warning does not print the value")
    end
    next if device.start_with?("twin") # the twin merge needs both devices

    solo = render(source, recipe_path, [[device, value, keep]])
    expected = keep ? ["# BEGIN ssh-keys-managed", today_line(device, value), "# END ssh-keys-managed"] : []
    say.call(solo[:block] == expected,
             "alone #{device}: #{keep ? 'the line as before' : 'no managed block written'}" +
               shown.call(solo[:block], expected))
  end

  # A managed block that already holds a tab-separated key and a peer key,
  # plus an unmanaged line: after the run both keys are still there.
  tab_line = "ssh-ed25519\t#{ED5}\ttab-dev"
  peer_line = "ssh-ed25519 #{ED1} peer"
  existing = "ssh-ed25519 #{ED2} hand-added\n\n# BEGIN ssh-keys-managed\n#{tab_line}\n#{peer_line}\n# END ssh-keys-managed\n"
  mixed = render(source, recipe_path, [["tab-dev", tab_line, true], ["peer", peer_line, true]], existing: existing)
  mixed_expected = ["# BEGIN ssh-keys-managed", tab_line, peer_line, "# END ssh-keys-managed"]
  say.call(mixed[:block] == mixed_expected, "existing block with a tab-separated key and a peer: both kept" +
           shown.call(mixed[:block], mixed_expected))
  say.call(mixed[:content].to_s.start_with?("ssh-ed25519 #{ED2} hand-added\n"), "existing block: unmanaged line kept")
  say.call(mixed[:content] == existing, "existing block: file content unchanged byte-for-byte")

  # sensitive on both authorized_keys file resources.
  plain = render(source, recipe_path, [["peer", peer_line, true]], existing: existing)
  say.call(plain[:written] && plain[:written][:sensitive] == true, "authorized_keys file resource is sensitive")
  pve = render(source, recipe_path, [["peer", peer_line, true]], pve: true)
  say.call(pve[:written] && pve[:written][:sensitive] == true &&
           pve[:block] == ["# BEGIN ssh-keys-managed", peer_line, "# END ssh-keys-managed"],
           "PVE staging file resource is sensitive and holds the block")
  failures
end

recipe = File.expand_path(ARGV[0] || DEFAULT_RECIPE)
source = File.read(recipe)
failures = run_cases("recipe", source, recipe)

if recipe == File.expand_path(DEFAULT_RECIPE)
  check = /^  pub_line, reject_reason = public_key_line\.call\(raw_pub\)\n  unless pub_line\n.*?^    next\n  end\n/m
  sensitive = "      # The old content (possibly a value a previous run should not have\n" \
              "      # distributed) would otherwise be printed in mitamae's file diff.\n" \
              "      sensitive true\n"
  mutants = {
    "positive-control: check replaced by the old strip" => source.sub(check, "  pub_line = raw_pub.strip\n"),
    "positive-control: authorized_keys files not sensitive" => source.gsub(sensitive, ""),
  }
  mutants.each do |name, mutant|
    if mutant == source
      failures += 1
      puts "FAIL  [#{name}] could not build the mutant from #{recipe} (pattern drifted)"
      next
    end
    mutant_failures = run_cases(name, mutant, recipe, quiet: true)
    ok = mutant_failures.positive?
    failures += 1 unless ok
    puts "#{ok ? 'PASS' : 'FAIL'}  [#{name}] the mutant fails #{mutant_failures} assertion(s)"
  end
end

puts(failures.positive? ? "FAILED: #{failures}" : "OK")
exit(failures.positive? ? 1 : 0)
