# frozen_string_literal: true
#
# Evaluates cookbooks/ssh-keys/default.rb (unmodified) under CRuby through a
# stub mitamae DSL: `aws ssm get-parameter --output text` answers from an
# in-memory fixture registry exactly as the CLI prints it (the stored value
# plus one newline), `hostname -s` answers "host-a", and resources are
# recorded instead of run. No AWS, no network. Key blobs are public halves of
# throwaway keys made with ssh-keygen for this test (sk-*, off-curve and
# zero-exponent blobs are assembled from them below).
#
# What this protects: every SSM `<ssm_prefix>/public` value is written into the
# authorized_keys managed block of EVERY fleet host. Only a value that is
# exactly one public key line may get there, and OpenSSH (ssh-keygen -l)
# decides what a public key is; everything else is skipped with a warning
# naming the SSM path (never the value). Valid keys — rsa, rsa-sha2-* labels,
# no comment, tab or several blanks between fields, long lines, twin keys
# whose comments are merged — must come out exactly as before. Both
# authorized_keys file resources (the normal file and the PVE pmxcfs staging
# file) must be `sensitive`.
#
# Modes (each runs the same recipe):
#   real   — the recipe's ssh-keygen / mktemp calls run the REAL programs
#            (inside a fixture temp dir). Needs ssh-keygen on PATH; without it
#            these assertions print SKIP, or FAIL when REQUIRE_SSH_KEYGEN=1
#            (CI sets it).
#   absent — `command -v ssh-keygen` fails: the Ruby checks still skip the
#            policy cases, every other line is kept as before, one warning
#            says the key material was not verified, ssh-keygen is never run.
#   mktemp — mktemp fails: same fallback, with its own warning.
#
# Positive controls: mutants of the recipe (check replaced by the old strip;
# no sensitive; no ssh-keygen probe; no second, first-field-dropped probe)
# MUST each fail; if one passes, this harness cannot see what it claims to
# test and the run FAILS.
#
# Usage: ruby test-public-key-validation.rb [RECIPE]
#   RECIPE defaults to ../default.rb. Passing another recipe (e.g. an older
#   version) runs the cases only, without the positive controls.
# Exit 0 when every assertion passes. One PASS/FAIL/SKIP line per assertion.
require "json"
require "open3"
require "tmpdir"

HERE = File.expand_path(__dir__)
DEFAULT_RECIPE = File.join(HERE, "..", "default.rb")
REQUIRE_SSH_KEYGEN = ENV["REQUIRE_SSH_KEYGEN"] == "1"
REAL_SSH_KEYGEN = system("command -v ssh-keygen >/dev/null 2>&1")

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

ED15 = "AAAAC3NzaC1lZDI1NTE5AAAAILmZxcIT+qhQ0nlWdnIMgZ0tbMiA9MSLLviHEep3X5Yt"
ED16 = "AAAAC3NzaC1lZDI1NTE5AAAAIIuWpzuPVXAvuHtMXtgll4y0YXayWtyNEeOebbGCdKuI"
ED17 = "AAAAC3NzaC1lZDI1NTE5AAAAICCE3K6KkDzXUHoBPjRvOBPKD571JGmaEuAO7W6D7gaN"
ED18 = "AAAAC3NzaC1lZDI1NTE5AAAAIBaxMchPDioN37z0Wja5HdPHb9XiJRYBxCkDFal1alW5"
ED19 = "AAAAC3NzaC1lZDI1NTE5AAAAIKl1yRC/uWB4O86N0f9SsJjzwIKcOIB63hT+7SE1wUlX"
ED20 = "AAAAC3NzaC1lZDI1NTE5AAAAIJm2wJqPK+ZgpjF/3mnOqfC7o0jXW3UTEJ88EpakHiP4"
ED21 = "AAAAC3NzaC1lZDI1NTE5AAAAIJhkCE7hb0+DHF3MzGcbUJTnctqyL1CYUcBze4p6hMqT"

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
EC256_OFF_CURVE_POINT = EC256_POINT[0, 64] + (EC256_POINT[64].ord ^ 1).chr.b # y changed by one bit
RSA2048_N = fields_of(RSA2048)[2]
SK_ED = b64(wire("sk-ssh-ed25519@openssh.com") + wire(ED7_PK) + wire("ssh:"))
SK_EC = b64(wire("sk-ecdsa-sha2-nistp256@openssh.com") + wire("nistp256") + wire(EC256_POINT) + wire("ssh:"))
EC256_OFF_CURVE = b64(wire("ecdsa-sha2-nistp256") + wire("nistp256") + wire(EC256_OFF_CURVE_POINT))
SK_EC_OFF_CURVE = b64(wire("sk-ecdsa-sha2-nistp256@openssh.com") + wire("nistp256") + wire(EC256_OFF_CURVE_POINT) +
                      wire("ssh:"))
RSA_ZERO_E = b64(wire("ssh-rsa") + wire("") + wire(RSA2048_N))
RSA512 = b64(wire("ssh-rsa") + wire("\x01\x00\x01".b) + wire("\x00\xC0".b + ("\x11".b * 63)))
ED_TRUNCATED = b64(unb64(ED1)[0, 30])
ED_TRAILING = b64(unb64(ED1) + "\x00".b)
ED_SHORT_PK = b64(wire("ssh-ed25519") + wire("\x01".b * 31))
ED_LONG_WIRE_LEN = b64("\x00\x00\x01\x00ssh-ed25519".b)
EC256_BAD_SLOP = EC256.sub(/Y3Y=\z/, "Y3Z=") # same length, non-zero bits after the last byte
EC256_NO_PAD = EC256.chomp("=")
EC256_COMPRESSED = b64(wire("ecdsa-sha2-nistp256") + wire("nistp256") + wire("\x02".b + EC256_POINT[1, 32]))
SK_NO_APP = b64(wire("sk-ssh-ed25519@openssh.com") + wire(ED7_PK))

def padded(prefix, total) = prefix + ("c" * (total - prefix.bytesize))

# [device, value as stored in SSM, kept with ssh-keygen?, kept without it?]
# A line kept "without ssh-keygen" is the fallback: the Ruby checks pass, so
# the line is kept as before this check.
CASES = [
  ["ed25519-comment", "ssh-ed25519 #{ED1} sh1@air", true, true],
  ["rsa-comment", "ssh-rsa #{RSA2048} sh1@mini", true, true],
  ["rsa1024-no-comment", "ssh-rsa #{RSA1024}", true, true],
  ["rsa-sha2-256-label", "rsa-sha2-256 #{RSA2048} label-256", true, true],
  ["rsa-sha2-512-label", "rsa-sha2-512 #{RSA2048} label-512", true, true],
  ["rsa-zero-exponent", "ssh-rsa #{RSA_ZERO_E} zero-e", true, true], # OpenSSH reads it, so it decides
  ["ecdsa-no-comment", "ecdsa-sha2-nistp256 #{EC256}", true, true],
  ["ecdsa384", "ecdsa-sha2-nistp384 #{EC384} p384", true, true],
  ["ecdsa521", "ecdsa-sha2-nistp521 #{EC521} p521", true, true],
  ["sk-ed25519", "sk-ssh-ed25519@openssh.com #{SK_ED} yubikey", true, true],
  ["sk-ecdsa", "sk-ecdsa-sha2-nistp256@openssh.com #{SK_EC} yubikey-ec", true, true],
  ["comment-spaces", "ssh-ed25519 #{ED2} shin ohno on pro", true, true],
  ["tab-separator", "ssh-ed25519\t#{ED5}\tsh1@tab", true, true],
  ["several-blanks", "ssh-ed25519   #{ED6}  \t sh1@blanks", true, true],
  ["tab-in-comment", "ssh-ed25519 #{ED8} a\tb", true, true],
  ["trailing-lf", "ssh-ed25519 #{ED9} stored-with-lf\n", true, true],
  ["trailing-crlf", "ssh-ed25519 #{ED10} stored-with-crlf\r\n", true, true],
  ["surrounding-blanks", "  ssh-ed25519 #{ED11} padded \t ", true, true],
  ["unicode-comment", "ssh-ed25519 #{ED12} 大野 — air", true, true],
  ["unicode-format-char", "ssh-ed25519 #{ED15} a‎b", true, true],
  ["line-4096", padded("ssh-ed25519 #{ED13} ", 4096), true, true],
  ["line-4097", padded("ssh-ed25519 #{ED16} ", 4097), true, true],
  ["line-8192", padded("ssh-ed25519 #{ED17} ", 8192), true, true],
  ["comment-8kib", "ssh-ed25519 #{ED18} #{'c' * 8192}", true, true],
  ["line-4096-trailing-space", "#{padded("ssh-ed25519 #{ED19} ", 4096)} ", true, true],
  ["twin-a", "ssh-ed25519 #{ED3}", true, true],
  ["twin-b", "ssh-ed25519 #{ED3}", true, true],
  ["twinc-a", "ssh-ed25519 #{ED4} sh1@pro", true, true],
  ["twinc-b", "ssh-ed25519 #{ED4} sh1@pro", true, true],
  # --- policy (Ruby): not one public key line ---
  ["ipad-yebisu", "placeholder — upload real public key with scripts/register_ios_key.sh", false, false],
  ["ipad", "placeholder — upload real public key via AWS Console", false, false],
  ["opt-command", "command=\"/bin/sh -c id\" ssh-ed25519 #{ED14} evil", false, false],
  ["opt-from", "from=\"10.0.0.0/8\",no-pty ssh-ed25519 #{ED14}", false, false],
  ["opt-restrict", "restrict ssh-ed25519 #{ED14}", false, false],
  ["opt-no-pty", "no-pty ssh-ed25519 #{ED14}", false, false],
  ["two-lines", "ssh-ed25519 #{ED14} a\nssh-ed25519 #{ED2} b", false, false],
  ["private-key", "-----BEGIN OPENSSH PRIVATE KEY-----\nb3BlbnNzaC1rZXktdjEAAAAABG5vbmU=\n-----END OPENSSH PRIVATE KEY-----", false, false],
  ["pem-one-line", "-----BEGIN OPENSSH PRIVATE KEY----- b3BlbnNzaC1rZXktdjEAAAAABG5vbmU=", false, false],
  ["empty", "", false, false],
  ["only-newline", "\n", false, false],
  ["type-only", "ssh-ed25519", false, false],
  ["leading-blank-line", "\nssh-ed25519 #{ED14} x", false, false],
  ["trailing-blank-line", "ssh-ed25519 #{ED14} x\n\n", false, false],
  ["trailing-blank-crlf", "ssh-ed25519 #{ED14} x\r\n\r\n", false, false],
  ["cr-inside", "ssh-ed25519 #{ED14} a\rb", false, false],
  ["cr-before-space", "ssh-ed25519 #{ED14}\r x", false, false],
  ["lone-trailing-cr", "ssh-ed25519 #{ED14} x\r", false, false],
  ["trailing-nul", "ssh-ed25519 #{ED14} x\u0000", false, false],
  ["nul-in-comment", "ssh-ed25519 #{ED14} a\u0000b", false, false],
  ["esc-in-comment", "ssh-ed25519 #{ED14} a\e[31mb", false, false],
  ["del-in-comment", "ssh-ed25519 #{ED14} a\u007Fb", false, false],
  ["u0085-in-comment", "ssh-ed25519 #{ED14} a\u0085b", false, false],
  ["u009b-in-comment", "ssh-ed25519 #{ED14} a\u009B31mb", false, false],
  ["u2028-in-comment", "ssh-ed25519 #{ED14} a b", false, false],
  ["u2029-in-comment", "ssh-ed25519 #{ED14} a b", false, false],
  # --- OpenSSH (ssh-keygen -l) decides: not a public key / key not at field 1 ---
  ["leading-unknown-word", "foo ssh-ed25519 #{ED20} x", false, true],
  ["hostname-prefix", "host.example ssh-ed25519 #{ED21} x", false, true],
  ["dss", "ssh-dss AAAAB3NzaC1kc3MAAACBAFixture dss", false, true],
  ["short-valid-base64", "ssh-ed25519 dGVzdA== x", false, true],
  ["truncated-blob", "ssh-ed25519 #{ED_TRUNCATED} x", false, true],
  ["trailing-data", "ssh-ed25519 #{ED_TRAILING} x", false, true],
  ["ed25519-31-bytes", "ssh-ed25519 #{ED_SHORT_PK} x", false, true],
  ["wire-length-too-long", "ssh-ed25519 #{ED_LONG_WIRE_LEN} x", false, true],
  ["type-mismatch", "ssh-rsa #{ED14} x", false, true],
  ["curve-mismatch", "ecdsa-sha2-nistp384 #{EC256} x", false, true],
  ["ecdsa-off-curve", "ecdsa-sha2-nistp256 #{EC256_OFF_CURVE} x", false, true],
  ["sk-ecdsa-off-curve", "sk-ecdsa-sha2-nistp256@openssh.com #{SK_EC_OFF_CURVE} x", false, true],
  ["bad-padding-bits", "ecdsa-sha2-nistp256 #{EC256_BAD_SLOP} x", false, true],
  ["missing-padding", "ecdsa-sha2-nistp256 #{EC256_NO_PAD} x", false, true],
  ["extra-padding", "ecdsa-sha2-nistp256 #{EC256}= x", false, true],
  ["padding-inside", "ssh-ed25519 #{ED14[0, 8]}=#{ED14[9..]} x", false, true],
  ["compressed-point", "ecdsa-sha2-nistp256 #{EC256_COMPRESSED} x", false, true],
  ["rsa-512-bits", "ssh-rsa #{RSA512} x", false, true],
  ["sk-no-application", "sk-ssh-ed25519@openssh.com #{SK_NO_APP} x", false, true],
  ["bad-blob-chars", "ssh-ed25519 AAAA$(id) x", false, true],
].freeze

TWIN_LINES = {
  "twin-a" => "ssh-ed25519 #{ED3} twin-a,twin-b",
  "twinc-a" => "ssh-ed25519 #{ED4} sh1@pro,twinc-b",
}.freeze

# The line the recipe wrote before the check for a value it keeps: the value
# stripped, plus the device name when it has no comment.
def today_line(device, value)
  line = value.strip
  line.split(/\s+/).length < 3 ? "#{line} #{device}" : line
end

BEGIN_LINE = "# BEGIN ssh-keys-managed"
END_LINE = "# END ssh-keys-managed"

# The managed block for every case kept with ssh-keygen (all distinct keys
# except the two twin pairs, whose comments merge).
EXPECTED_BLOCK = ([BEGIN_LINE] +
  CASES.select { |c| c[2] }.reject { |c| %w[twin-b twinc-b].include?(c[0]) }
       .map { |device, value, _, _| TWIN_LINES[device] || today_line(device, value) } +
  [END_LINE]).freeze

module MItamae
  @messages = []
  class << self
    attr_reader :messages

    def logger
      log = Object.new
      msgs = @messages
      %i[info warn debug error].each { |level| log.define_singleton_method(level) { |m| msgs << [level, m] } }
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

  attr_reader :node, :files, :keygen_calls, :temp_dirs, :candidates

  # mode: :real (run ssh-keygen / mktemp for real), :absent, :mktemp_fails
  def initialize(home, ssm, mode)
    @home = home
    @ssm = ssm
    @mode = mode
    @files = {}
    @keygen_calls = 0
    @temp_dirs = []
    @candidates = []
    @node = { setup: { user: "fixture", group: "fixture", home: home, root: "#{home}/.setup" } }
  end

  def include_platform_cookbook(_name); end

  def require_external_auth(**_opts); end

  def run_command(command, **_opts)
    return array_command(command) if command.is_a?(Array)
    return Result.new("host-a\n", 0) if command == "hostname -s"
    return Result.new("", @mode == :absent ? 1 : 0) if command == "command -v ssh-keygen >/dev/null 2>&1"

    name = command[/--name '([^']+)'/, 1]
    raise "unexpected command: #{command}" unless command.start_with?("aws ssm get-parameter") && name
    return Result.new("", 255) unless @ssm.key?(name)

    # aws ssm get-parameter --output text: the value plus one newline.
    Result.new("#{@ssm[name]}\n", 0)
  end

  # The argv commands the recipe may spawn. Real programs run only inside a
  # fixture temp dir; rm / rmdir are done in Ruby on that dir only.
  def array_command(argv)
    case argv
    in ["mktemp", "-d"]
      return Result.new("", 1) if @mode == :mktemp_fails
      raise "mktemp called in #{@mode} mode" unless @mode == :real

      out, status = Open3.capture2({ "TMPDIR" => @home }, "mktemp", "-d")
      @temp_dirs << out.strip
      Result.new(out, status.exitstatus)
    in ["ssh-keygen", "-l", "-f", path]
      raise "ssh-keygen called in #{@mode} mode" unless @mode == :real
      raise "candidate outside the temp dir: #{path}" unless @temp_dirs.any? { |d| path.start_with?("#{d}/") }

      @keygen_calls += 1
      # Permissions of the candidate and its directory. This file runs on
      # CRuby; lstat (no symlinks here) because bin/lint-cookbooks scans test/
      # as recipe Ruby and flags File.stat as mruby-absent.
      @candidates << [::File.lstat(path).mode & 0o777, ::File.lstat(::File.dirname(path)).mode & 0o777]
      out, _err, status = Open3.capture3("ssh-keygen", "-l", "-f", path)
      Result.new(out, status.exitstatus)
    in ["rm", "-f", path] if @temp_dirs.any? { |d| path.start_with?("#{d}/") }
      ::File.delete(path) if ::File.exist?(path)
      Result.new("", 0)
    in ["rmdir", dir] if @temp_dirs.include?(dir)
      Dir.rmdir(dir)
      Result.new("", 0)
    else
      raise "unexpected argv command: #{argv.inspect}"
    end
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
  cases.each do |device, value, *|
    devices[device] = { "client_only" => true, "ssh" => { "ssm_prefix" => "/ssh-keys/devices/#{device}" } }
    ssm["/ssh-keys/devices/#{device}/public"] = value
  end
  ssm["/host-registry/devices"] = JSON.generate("devices" => devices)
  ssm
end

def managed_block(content)
  lines = content ? content.lines.map(&:chomp) : []
  first = lines.index(BEGIN_LINE)
  last = lines.index(END_LINE)
  first && last ? lines[first..last] : []
end

# Evaluates the recipe source with __FILE__ = the real recipe path (so
# files/aws-config.json resolves).
def render(source, recipe_path, cases, mode:, existing: nil, pve: false)
  MItamae.messages.clear
  Dir.mktmpdir("ssh-keys-test-") do |home|
    auth = "#{home}/.ssh/authorized_keys"
    if existing
      Dir.mkdir("#{home}/.ssh")
      File.write(auth, existing)
    end
    RecipeFixture::File.pve_link = pve ? auth : nil
    fixture = RecipeFixture.new(home, registry_for(cases), mode)
    begin
      fixture.instance_eval(source, recipe_path)
    ensure
      RecipeFixture::File.pve_link = nil
    end
    target = pve ? "#{home}/.setup/ssh-keys/authorized_keys.staged" : auth
    written = fixture.files[target]
    warnings = MItamae.messages.select { |level, _| level == :warn }.map { |_, m| m }
                      .reject { |w| w.include?("/ssh-keys/devices/host-a/") } # host-a has no fixture keys
    return { block: managed_block(written && written[:content]), content: written && written[:content],
             written: written, warnings: warnings, keygen_calls: fixture.keygen_calls,
             temp_dirs: fixture.temp_dirs, candidates: fixture.candidates }
  end
end

class Reporter
  attr_reader :failures

  def initialize(label, quiet)
    @label = label
    @quiet = quiet
    @failures = 0
  end

  def check(ok, msg)
    @failures += 1 unless ok
    puts "#{ok ? 'PASS' : 'FAIL'}  [#{@label}] #{msg}" unless @quiet
  end

  def skip(msg)
    if REQUIRE_SSH_KEYGEN
      check(false, "#{msg} (ssh-keygen not on PATH and REQUIRE_SSH_KEYGEN=1)")
    else
      puts "SKIP  [#{@label}] #{msg} (ssh-keygen not on PATH)" unless @quiet
    end
  end
end

def shown(got, want) = got == want ? "" : " (got #{got.inspect[0, 300]})"

def skip_assertions(r, all, device, value)
  path = "/ssh-keys/devices/#{device}/public"
  r.check(all[:warnings].any? { |w| w.include?(path) }, "skip #{device}: warning names #{path}")
  # Pieces of the value long enough to identify it (not a 1-char tail).
  pieces = value.split(/[\r\n\u0000]/).map(&:strip).select { |piece| piece.length > 12 }
  r.check(pieces.none? { |piece| all[:block].any? { |b| b.include?(piece) } }, "skip #{device}: value not in managed block")
  r.check(all[:warnings].none? { |w| pieces.any? { |piece| w.include?(piece) } },
          "skip #{device}: warning does not print the value")
end

def real_mode(r, source, recipe_path)
  all = render(source, recipe_path, CASES, mode: :real)
  r.check(all[:block] == EXPECTED_BLOCK, "real: all cases give exactly the kept lines, unchanged" +
          shown(all[:block], EXPECTED_BLOCK))
  r.check(all[:keygen_calls] >= CASES.count { |c| c[2] } * 2, "real: ssh-keygen ran twice per kept value " \
          "(#{all[:keygen_calls]} calls)")
  r.check(!all[:candidates].empty? && all[:candidates].all? { |_, dir_mode| dir_mode == 0o700 },
          "real: candidate files live in a 0700 mktemp dir")
  r.check(all[:temp_dirs].length == 1 && all[:temp_dirs].none? { |d| Dir.exist?(d) },
          "real: one temp dir, removed after the loop")

  CASES.each do |device, value, keep, _|
    path = "/ssh-keys/devices/#{device}/public"
    if keep
      r.check(all[:warnings].none? { |w| w.include?(path) }, "real keep #{device}: no warning")
    else
      skip_assertions(r, all, device, value)
    end
    next if device.start_with?("twin")

    solo = render(source, recipe_path, [[device, value, keep]], mode: :real)
    want = keep ? [BEGIN_LINE, today_line(device, value), END_LINE] : []
    r.check(solo[:block] == want, "real alone #{device}: #{keep ? 'the line as before' : 'no managed block'}" +
            shown(solo[:block], want))
  end

  # Existing managed blocks with an unmanaged line: every valid key stays and
  # the file content does not change.
  peer = "ssh-ed25519 #{ED1} peer"
  [
    ["tab-separated key", "ssh-ed25519\t#{ED5}\ttab-dev"],
    ["4097-byte key", padded("ssh-ed25519 #{ED16} ", 4097)],
    ["rsa-sha2-256 key", "rsa-sha2-256 #{RSA2048} label-dev"],
  ].each do |name, line|
    existing = "ssh-ed25519 #{ED2} hand-added\n\n#{BEGIN_LINE}\n#{line}\n#{peer}\n#{END_LINE}\n"
    got = render(source, recipe_path, [["dev", line, true], ["peer", peer, true]], mode: :real, existing: existing)
    r.check(got[:block] == [BEGIN_LINE, line, peer, END_LINE], "real existing block with a #{name} and a peer: both kept" +
            shown(got[:block], [BEGIN_LINE, line, peer, END_LINE]))
    r.check(got[:content] == existing, "real existing block with a #{name}: file unchanged byte-for-byte")
  end
end

def fallback_mode(r, source, recipe_path, mode, warning)
  label = mode == :absent ? "no ssh-keygen" : "mktemp fails"
  all = render(source, recipe_path, CASES, mode: mode)
  r.check(all[:warnings].count { |w| w.include?(warning) } == 1, "#{label}: one warning '#{warning}'")
  r.check(all[:keygen_calls] == 0, "#{label}: ssh-keygen never runs")
  CASES.each do |device, value, _keep_real, keep|
    path = "/ssh-keys/devices/#{device}/public"
    if keep
      solo = render(source, recipe_path, [[device, value]], mode: mode)
      want = [BEGIN_LINE, today_line(device, value), END_LINE]
      r.check(solo[:block] == want && solo[:warnings].none? { |w| w.include?(path) },
              "#{label} keep #{device}: kept as before" + shown(solo[:block], want))
    else
      skip_assertions(r, all, device, value)
    end
  end
end

def run_cases(label, source, recipe_path, quiet: false)
  r = Reporter.new(label, quiet)
  if REAL_SSH_KEYGEN
    real_mode(r, source, recipe_path)
  else
    r.skip("real-mode cases")
  end
  fallback_mode(r, source, recipe_path, :absent, "ssh-keygen not found")
  fallback_mode(r, source, recipe_path, :mktemp_fails, "mktemp -d failed")

  peer = "ssh-ed25519 #{ED1} peer"
  existing = "#{BEGIN_LINE}\nssh-ed25519 #{ED2} old\n#{END_LINE}\n"
  plain = render(source, recipe_path, [["peer", peer]], mode: :absent, existing: existing)
  r.check(plain[:written] && plain[:written][:sensitive] == true, "authorized_keys file resource is sensitive")
  pve = render(source, recipe_path, [["peer", peer]], mode: :absent, pve: true)
  r.check(pve[:written] && pve[:written][:sensitive] == true && pve[:block] == [BEGIN_LINE, peer, END_LINE],
          "PVE staging file resource is sensitive and holds the block")
  r.failures
end

recipe = File.expand_path(ARGV[0] || DEFAULT_RECIPE)
source = File.read(recipe)
failures = run_cases("recipe", source, recipe)

if recipe == File.expand_path(DEFAULT_RECIPE)
  check = /^  pub_line, reject_reason = public_key_line\.call\(raw_pub\)\n  unless pub_line\n.*?^    next\n  end\n/m
  sensitive = "      # The old content (possibly a value a previous run should not have\n" \
              "      # distributed) would otherwise be printed in mitamae's file diff.\n" \
              "      sensitive true\n"
  probes = /^  if ssh_keygen_found\n    whole = .*?^    end\n  end\n/m
  second = /^      return \[nil, "the key does not start at the first field.*\n/
  mutants = {
    "positive-control: check replaced by the old strip" => [source.sub(check, "  pub_line = raw_pub.strip\n"), false],
    "positive-control: authorized_keys files not sensitive" => [source.gsub(sensitive, ""), false],
    "positive-control: no ssh-keygen probe" => [source.sub(probes, ""), true],
    "positive-control: no first-field-dropped probe" => [source.sub(second, ""), true],
  }
  mutants.each do |name, (mutant, needs_keygen)|
    if mutant == source
      failures += 1
      puts "FAIL  [#{name}] could not build the mutant from #{recipe} (pattern drifted)"
      next
    end
    if needs_keygen && !REAL_SSH_KEYGEN
      rep = Reporter.new(name, false)
      rep.skip("mutant needs real ssh-keygen")
      failures += rep.failures
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
