# frozen_string_literal: true
#
# Compares cookbooks/ssh-keys/default.rb (HEAD) with the recipe as it was on
# main before the public-value guard (BASE_COMMIT), both evaluated unmodified
# under CRuby through a stub mitamae DSL: `aws ssm get-parameter --output text`
# answers from an in-memory fixture registry exactly as the CLI prints it (the
# stored value plus one newline), `hostname -s` answers "host-a", any other
# command raises, and resources are recorded instead of run. No AWS, no
# network except fetching BASE_COMMIT when the checkout is shallow (CI).
#
# What this protects: every SSM `<ssm_prefix>/public` value is written into the
# authorized_keys managed block of EVERY fleet host. HEAD skips only three
# shapes, each with exactly one warning naming the SSM path (never the value):
#   placeholder — the value starts with "placeholder"
#   multiline   — more than one line (one trailing LF or CRLF allowed)
#   key_type    — the first whitespace-separated field is not ssh-*, ecdsa-*
#                 or sk-*
# Every other value must come out byte-for-byte as BASE writes it. For a
# skipped value the reference is BASE with that SSM value absent (its fetch
# fails), so the rest of the file must still match byte-for-byte.
#
# Cases: the fixtures of the earlier versions of this test plus every case of
# the three review rounds of PR #1231 (round 1: review-boundary.rb, round 2:
# review-boundary.rb, round 3: review-extra.rb); the column `src` names the
# source. Round 3's ssh-keygen / mktemp failure modes do not apply: HEAD runs
# no command but the aws / hostname calls BASE runs, which is asserted.
#
# Positive controls: mutants of HEAD (guard removed, each of the three checks
# removed, sensitive removed, value written unstripped) MUST each fail; if one
# passes, this harness cannot see what it claims to test and the run FAILS.
#
# Usage: ruby test-public-key-validation.rb [RECIPE]
#   RECIPE defaults to ../default.rb (mutants run only for the default).
#   SSH_KEYS_BASE_REF overrides BASE_COMMIT (e.g. origin/main).
#   REQUIRE_BASE_RECIPE=1 (CI) turns "BASE not available" into a failure.
# Exit 0 when every assertion passes. One PASS/FAIL/SKIP line per assertion.
require "json"
require "open3"
require "tmpdir"

HERE = File.expand_path(__dir__)
REPO = File.expand_path(File.join(HERE, "..", "..", ".."))
DEFAULT_RECIPE = File.join(HERE, "..", "default.rb")
RECIPE_IN_REPO = "cookbooks/ssh-keys/default.rb"
# origin/main when the guard was written (ssh-keys/default.rb last changed in
# 8749404). The comparison stays pinned to it after the guard is merged.
BASE_COMMIT = "539fe71685b34893a0de166e8eff52f2bf38806a"
BASE_REF = ENV["SSH_KEYS_BASE_REF"] || BASE_COMMIT
REQUIRE_BASE = ENV["REQUIRE_BASE_RECIPE"] == "1"

# --- key material (public halves of throwaway keys; blobs built from them) ---

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
ED15 = "AAAAC3NzaC1lZDI1NTE5AAAAILmZxcIT+qhQ0nlWdnIMgZ0tbMiA9MSLLviHEep3X5Yt"
ED16 = "AAAAC3NzaC1lZDI1NTE5AAAAIIuWpzuPVXAvuHtMXtgll4y0YXayWtyNEeOebbGCdKuI"
ED17 = "AAAAC3NzaC1lZDI1NTE5AAAAICCE3K6KkDzXUHoBPjRvOBPKD571JGmaEuAO7W6D7gaN"
ED18 = "AAAAC3NzaC1lZDI1NTE5AAAAIBaxMchPDioN37z0Wja5HdPHb9XiJRYBxCkDFal1alW5"
ED19 = "AAAAC3NzaC1lZDI1NTE5AAAAIKl1yRC/uWB4O86N0f9SsJjzwIKcOIB63hT+7SE1wUlX"
ED20 = "AAAAC3NzaC1lZDI1NTE5AAAAIJm2wJqPK+ZgpjF/3mnOqfC7o0jXW3UTEJ88EpakHiP4"
ED21 = "AAAAC3NzaC1lZDI1NTE5AAAAIJhkCE7hb0+DHF3MzGcbUJTnctqyL1CYUcBze4p6hMqT"
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
# Public test certificate of openssh-portable
# (regress/misc/fuzz-harness/testdata/id_ed25519-cert.pub), used by round 3.
ED_CERT = "ssh-ed25519-cert-v01@openssh.com AAAAIHNzaC1lZDI1NTE5LWNlcnQtdjAxQG9wZW5zc2guY29tAAAAIMDQjYH6XRz" \
          "H3j3MW1DdjCoAfvrHfgjnVGF+sLK0pBfqAAAAIDPQXmEVMVLmeFRyafKMVWgPDkv8/uRBTwmcEDatZzMDAAAAAAAAA+sAAAA" \
          "BAAAAB3VseXNzZXMAAAAXAAAAB3VseXNzZXMAAAAIb2R5c3NldXMAAAAAAAAAAP//////////AAAAAAAAAIIAAAAVcGVybWl" \
          "0LVgxMS1mb3J3YXJkaW5nAAAAAAAAABdwZXJtaXQtYWdlbnQtZm9yd2FyZGluZwAAAAAAAAAWcGVybWl0LXBvcnQtZm9yd2F" \
          "yZGluZwAAAAAAAAAKcGVybWl0LXB0eQAAAAAAAAAOcGVybWl0LXVzZXItcmMAAAAAAAAAAAAAADMAAAALc3NoLWVkMjU1MTk" \
          "AAAAgM9BeYRUxUuZ4VHJp8oxVaA8OS/z+5EFPCZwQNq1nMwMAAABTAAAAC3NzaC1lZDI1NTE5AAAAQBj0og+s09/HpwdHZbz" \
          "N0twooKPDWWrxGfnP1Joy6cDnY2BCSQ7zg9vbq11kLF8H/sKOTZWAQrUZ7LlChOu9Ogw= id_ed25519.pub"

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
EC256_ZERO_POINT = b64(wire("ecdsa-sha2-nistp256") + wire("nistp256") + wire("\x04".b + ("\x00".b * 64)))
SK_EC_ZERO_POINT = b64(wire("sk-ecdsa-sha2-nistp256@openssh.com") + wire("nistp256") +
                       wire("\x04".b + ("\x00".b * 64)) + wire("ssh:"))
RSA_ZERO_E = b64(wire("ssh-rsa") + wire("") + wire(RSA2048_N))
RSA512 = b64(wire("ssh-rsa") + wire("\x01\x00\x01".b) + wire("\x00\xC0".b + ("\x11".b * 63)))
ED_TRUNCATED = b64(unb64(ED1)[0, 30])
ED_TRAILING = b64(unb64(ED1) + "\x00".b)
ED_SHORT_PK = b64(wire("ssh-ed25519") + wire("\x01".b * 31))
ED_LONG_WIRE_LEN = b64("\x00\x00\x01\x00ssh-ed25519".b)
ED_MAX_WIRE_LEN = b64([0xffff_ffff].pack("N"))
EC256_BAD_SLOP = EC256.sub(/Y3Y=\z/, "Y3Z=") # same length, non-zero bits after the last byte
EC256_NO_PAD = EC256.chomp("=")
EC256_COMPRESSED = b64(wire("ecdsa-sha2-nistp256") + wire("nistp256") + wire("\x02".b + EC256_POINT[1, 32]))
SK_NO_APP = b64(wire("sk-ssh-ed25519@openssh.com") + wire(ED7_PK))
# Round 1 built its ed25519 blobs from fixed hex points.
R1_ONE = b64(wire("ssh-ed25519") + wire(["d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a"].pack("H*")))
R1_TWO = b64(wire("ssh-ed25519") + wire(["3d4017c3e843895a92b70aa74d1b7ebc9c982ccf2ec4968cc0cd55f12af4660c"].pack("H*")))

def padded(prefix, total, fill = "c") = prefix + (fill * (total - prefix.bytesize))

R1_LINE = "ssh-ed25519 #{R1_ONE} fixture"
R2_BASE = "ssh-ed25519 #{ED13}"
R3_PLAIN = "ssh-ed25519 #{ED5}"

# [src, device, value as stored in SSM, shape HEAD skips it as (nil = kept)]
# src: fixture = earlier versions of this test; r1 / r2 / r3 = review rounds.
CASES = [
  # --- earlier fixtures ---
  ["fixture", "ed25519-comment", "ssh-ed25519 #{ED1} sh1@air", nil],
  ["fixture", "rsa-comment", "ssh-rsa #{RSA2048} sh1@mini", nil],
  ["fixture", "rsa1024-no-comment", "ssh-rsa #{RSA1024}", nil],
  ["fixture", "rsa-sha2-256-label", "rsa-sha2-256 #{RSA2048} label-256", :key_type],
  ["fixture", "rsa-sha2-512-label", "rsa-sha2-512 #{RSA2048} label-512", :key_type],
  ["fixture", "rsa-zero-exponent", "ssh-rsa #{RSA_ZERO_E} zero-e", nil],
  ["fixture", "ecdsa-no-comment", "ecdsa-sha2-nistp256 #{EC256}", nil],
  ["fixture", "ecdsa384", "ecdsa-sha2-nistp384 #{EC384} p384", nil],
  ["fixture", "ecdsa521", "ecdsa-sha2-nistp521 #{EC521} p521", nil],
  ["fixture", "sk-ed25519", "sk-ssh-ed25519@openssh.com #{SK_ED} yubikey", nil],
  ["fixture", "sk-ecdsa", "sk-ecdsa-sha2-nistp256@openssh.com #{SK_EC} yubikey-ec", nil],
  ["fixture", "comment-spaces", "ssh-ed25519 #{ED2} shin ohno on pro", nil],
  ["fixture", "tab-separator", "ssh-ed25519\t#{ED5}\tsh1@tab", nil],
  ["fixture", "several-blanks", "ssh-ed25519   #{ED6}  \t sh1@blanks", nil],
  ["fixture", "tab-in-comment", "ssh-ed25519 #{ED8} a\tb", nil],
  ["fixture", "trailing-lf", "ssh-ed25519 #{ED9} stored-with-lf\n", nil],
  ["fixture", "trailing-crlf", "ssh-ed25519 #{ED10} stored-with-crlf\r\n", nil],
  ["fixture", "surrounding-blanks", "  ssh-ed25519 #{ED11} padded \t ", nil],
  ["fixture", "unicode-comment", "ssh-ed25519 #{ED12} 大野 — air", nil],
  ["fixture", "unicode-format-char", "ssh-ed25519 #{ED15} a‎b", nil],
  ["fixture", "line-4096", padded("ssh-ed25519 #{ED13} ", 4096), nil],
  ["fixture", "line-4097", padded("ssh-ed25519 #{ED16} ", 4097), nil],
  ["fixture", "line-8192", padded("ssh-ed25519 #{ED17} ", 8192), nil],
  ["fixture", "comment-8kib", "ssh-ed25519 #{ED18} #{'c' * 8192}", nil],
  ["fixture", "line-4096-trailing-space", "#{padded("ssh-ed25519 #{ED19} ", 4096)} ", nil],
  ["fixture", "twin-a", "ssh-ed25519 #{ED3}", nil],
  ["fixture", "twin-b", "ssh-ed25519 #{ED3}", nil],
  ["fixture", "twinc-a", "ssh-ed25519 #{ED4} sh1@pro", nil],
  ["fixture", "twinc-b", "ssh-ed25519 #{ED4} sh1@pro", nil],
  ["fixture", "ipad-yebisu", "placeholder — upload real public key with scripts/register_ios_key.sh", :placeholder],
  ["fixture", "ipad", "placeholder — upload real public key via AWS Console", :placeholder],
  ["fixture", "opt-command", "command=\"/bin/sh -c id\" ssh-ed25519 #{ED14} evil", :key_type],
  ["fixture", "opt-from", "from=\"10.0.0.0/8\",no-pty ssh-ed25519 #{ED14}", :key_type],
  ["fixture", "opt-restrict", "restrict ssh-ed25519 #{ED14}", :key_type],
  ["fixture", "opt-no-pty", "no-pty ssh-ed25519 #{ED14}", :key_type],
  ["fixture", "two-lines", "ssh-ed25519 #{ED14} a\nssh-ed25519 #{ED2} b", :multiline],
  ["fixture", "private-key", "-----BEGIN OPENSSH PRIVATE KEY-----\nb3BlbnNzaC1rZXktdjEAAAAABG5vbmU=\n" \
                             "-----END OPENSSH PRIVATE KEY-----", :multiline],
  ["fixture", "pem-one-line", "-----BEGIN OPENSSH PRIVATE KEY----- b3BlbnNzaC1rZXktdjEAAAAABG5vbmU=", :key_type],
  ["fixture", "empty", "", :key_type],
  ["fixture", "only-newline", "\n", :key_type],
  ["fixture", "type-only", "ssh-ed25519", nil],
  ["fixture", "leading-blank-line", "\nssh-ed25519 #{ED14} x", :multiline],
  ["fixture", "trailing-blank-line", "ssh-ed25519 #{ED14} x\n\n", :multiline],
  ["fixture", "trailing-blank-crlf", "ssh-ed25519 #{ED14} x\r\n\r\n", :multiline],
  ["fixture", "cr-inside", "ssh-ed25519 #{ED14} a\rb", nil],
  ["fixture", "cr-before-space", "ssh-ed25519 #{ED14}\r x", nil],
  ["fixture", "lone-trailing-cr", "ssh-ed25519 #{ED14} x\r", nil],
  ["fixture", "trailing-nul", "ssh-ed25519 #{ED14} x\u0000", nil],
  ["fixture", "nul-in-comment", "ssh-ed25519 #{ED14} a\u0000b", nil],
  ["fixture", "esc-in-comment", "ssh-ed25519 #{ED14} a\e[31mb", nil],
  ["fixture", "del-in-comment", "ssh-ed25519 #{ED14} a\u007Fb", nil],
  ["fixture", "u0085-in-comment", "ssh-ed25519 #{ED14} a\u0085b", nil],
  ["fixture", "u009b-in-comment", "ssh-ed25519 #{ED14} a\u009B31mb", nil],
  ["fixture", "u2028-in-comment", "ssh-ed25519 #{ED14} a b", nil],
  ["fixture", "u2029-in-comment", "ssh-ed25519 #{ED14} a b", nil],
  ["fixture", "leading-unknown-word", "foo ssh-ed25519 #{ED20} x", :key_type],
  ["fixture", "hostname-prefix", "host.example ssh-ed25519 #{ED21} x", :key_type],
  ["fixture", "dss", "ssh-dss AAAAB3NzaC1kc3MAAACBAFixture dss", nil],
  ["fixture", "short-valid-base64", "ssh-ed25519 dGVzdA== x", nil],
  ["fixture", "truncated-blob", "ssh-ed25519 #{ED_TRUNCATED} x", nil],
  ["fixture", "trailing-data", "ssh-ed25519 #{ED_TRAILING} x", nil],
  ["fixture", "ed25519-31-bytes", "ssh-ed25519 #{ED_SHORT_PK} x", nil],
  ["fixture", "wire-length-too-long", "ssh-ed25519 #{ED_LONG_WIRE_LEN} x", nil],
  ["fixture", "type-mismatch", "ssh-rsa #{ED14} x", nil],
  ["fixture", "curve-mismatch", "ecdsa-sha2-nistp384 #{EC256} x", nil],
  ["fixture", "ecdsa-off-curve", "ecdsa-sha2-nistp256 #{EC256_OFF_CURVE} x", nil],
  ["fixture", "sk-ecdsa-off-curve", "sk-ecdsa-sha2-nistp256@openssh.com #{SK_EC_OFF_CURVE} x", nil],
  ["fixture", "bad-padding-bits", "ecdsa-sha2-nistp256 #{EC256_BAD_SLOP} x", nil],
  ["fixture", "missing-padding", "ecdsa-sha2-nistp256 #{EC256_NO_PAD} x", nil],
  ["fixture", "extra-padding", "ecdsa-sha2-nistp256 #{EC256}= x", nil],
  ["fixture", "padding-inside", "ssh-ed25519 #{ED14[0, 8]}=#{ED14[9..]} x", nil],
  ["fixture", "compressed-point", "ecdsa-sha2-nistp256 #{EC256_COMPRESSED} x", nil],
  ["fixture", "rsa-512-bits", "ssh-rsa #{RSA512} x", nil],
  ["fixture", "sk-no-application", "sk-ssh-ed25519@openssh.com #{SK_NO_APP} x", nil],
  ["fixture", "bad-blob-chars", "ssh-ed25519 AAAA$(id) x", nil],
  # --- review round 1 (1ea73c9037d8437a review-boundary.rb) ---
  ["r1", "r1-valid-spaces", "ssh-ed25519  #{R1_ONE}  fixture", nil],
  ["r1", "r1-valid-tab-separator", "ssh-ed25519\t#{R1_ONE}\tfixture", nil],
  ["r1", "r1-trailing-spaces", "#{R1_LINE}  ", nil],
  ["r1", "r1-trailing-tab", "#{R1_LINE}\t", nil],
  ["r1", "r1-trailing-crlf", "#{R1_LINE}\r\n", nil],
  ["r1", "r1-trailing-cr-before-space", "#{R1_LINE}\r ", nil],
  ["r1", "r1-trailing-blank-line", "#{R1_LINE}\n\n", :multiline],
  ["r1", "r1-leading-blank-line", "\n#{R1_LINE}", :multiline],
  ["r1", "r1-trailing-nul", "#{R1_LINE}\u0000", nil],
  ["r1", "r1-internal-cr", "#{R1_LINE}\rcontinued", nil],
  ["r1", "r1-unicode-keytype-lookalike", R1_LINE.sub("-", "‐"), :key_type],
  ["r1", "r1-unicode-blob-lookalike", R1_LINE.sub(R1_ONE, "Ａ#{R1_ONE[1..]}"), nil],
  ["r1", "r1-unicode-comment", "#{R1_LINE} 日本語", nil],
  ["r1", "r1-unicode-c1-control-in-comment", "#{R1_LINE}\u0085continued", nil],
  ["r1", "r1-canonical-base64-no-key", "ssh-ed25519 YWJj fixture", nil],
  ["r1", "r1-invalid-base64-padding", "ssh-ed25519 YWJj=== fixture", nil],
  ["r1", "r1-8192-byte-value", R1_LINE.ljust(8192, "a"), nil],
  # --- review round 2 (2ec86d891f5246b4 review-boundary.rb) ---
  ["r2", "r2-plain", "#{R2_BASE} fixture", nil],
  ["r2", "r2-tab-separator", "ssh-ed25519\t#{ED5}\tfixture", nil],
  ["r2", "r2-mixed-separators", "ssh-ed25519 \t  #{ED6}\t \t fixture", nil],
  ["r2", "r2-trailing-blanks", "#{R2_BASE} fixture \t ", nil],
  ["r2", "r2-one-lf", "#{R2_BASE} fixture\n", nil],
  ["r2", "r2-one-crlf", "#{R2_BASE} 日本語\r\n", nil],
  ["r2", "r2-leading-blank", "\n#{R2_BASE} fixture", :multiline],
  ["r2", "r2-trailing-blank", "#{R2_BASE} fixture\n\n", :multiline],
  ["r2", "r2-cr-before-space", "#{R2_BASE}\r fixture", nil],
  ["r2", "r2-cr-in-comment", "#{R2_BASE} fi\rxture", nil],
  ["r2", "r2-trailing-nul", "#{R2_BASE} fixture\u0000", nil],
  ["r2", "r2-c1-u0085", "#{R2_BASE} fixture\u0085end", nil],
  ["r2", "r2-u2029", "#{R2_BASE} fixture end", nil],
  ["r2", "r2-unicode-format-character", "#{R2_BASE} fixture‎end", nil],
  ["r2", "r2-short-base64", "ssh-ed25519 dGVzdA== fixture", nil],
  ["r2", "r2-bad-padding", "ssh-ed25519 dGVzdA=== fixture", nil],
  ["r2", "r2-valid-rsa", "ssh-rsa #{RSA2048} fixture", nil],
  ["r2", "r2-valid-ecdsa", "ecdsa-sha2-nistp256 #{EC256} fixture", nil],
  ["r2", "r2-ecdsa-off-curve", "ecdsa-sha2-nistp256 #{EC256_ZERO_POINT} fixture", nil],
  ["r2", "r2-sk-ecdsa-off-curve", "sk-ecdsa-sha2-nistp256@openssh.com #{SK_EC_ZERO_POINT} fixture", nil],
  ["r2", "r2-rsa-zero-exponent", "ssh-rsa #{RSA_ZERO_E} fixture", nil],
  ["r2", "r2-rsa-sha2-256-label", "rsa-sha2-256 #{RSA2048} fixture", :key_type],
  ["r2", "r2-rsa-sha2-512-label", "rsa-sha2-512 #{RSA2048} fixture", :key_type],
  ["r2", "r2-wire-string-long-length", "ssh-ed25519 #{ED_MAX_WIRE_LEN} fixture", nil],
  ["r2", "r2-line-4096", padded("#{R2_BASE} ", 4096, "x"), nil],
  ["r2", "r2-line-4097", padded("#{R2_BASE} ", 4097, "x"), nil],
  ["r2", "r2-line-8192", padded("#{R2_BASE} ", 8192, "x"), nil],
  ["r2", "r2-comment-8192", "#{R2_BASE} #{'x' * 8192}", nil],
  ["r2", "r2-line-4096-plus-trailing-space", "#{padded("#{R2_BASE} ", 4096, 'x')} ", nil],
  ["r2", "r2-placeholder", "placeholder — awaiting a public key", :placeholder],
  # --- review round 3 (d0491533c8104075 review-extra.rb) ---
  ["r3", "r3-comment-is-another-public-key", "#{R3_PLAIN} ssh-ed25519 #{ED6}", nil],
  ["r3", "r3-comment-starts-with-word", "#{R3_PLAIN} note ssh-ed25519 #{ED6}", nil],
  ["r3", "r3-hostname-prefix", "host.example #{R3_PLAIN} fixture", :key_type],
  ["r3", "r3-unknown-prefix", "unknown #{R3_PLAIN} fixture", :key_type],
  ["r3", "r3-bare-option", "restrict #{R3_PLAIN} fixture", :key_type],
  ["r3", "r3-valued-option", "command=\"fixture only\" #{R3_PLAIN} fixture", :key_type],
  ["r3", "r3-comment-line", "# #{R3_PLAIN}", :key_type],
  ["r3", "r3-fingerprint-comment-log", "#{R3_PLAIN} review-synthetic-log-marker", nil],
  ["r3", "r3-bare-openssh-certificate", ED_CERT, nil],
  ["r3", "r3-invalid-short-base64", "ssh-ed25519 YWJj fixture", nil],
  ["r3", "r3-non-key-ascii-text", "draft fixture", :key_type],
  ["r3", "r3-valid-blob-with-shell-punctuation-comment", "#{R3_PLAIN} example ' ; & [ ]", nil],
  # --- edges of the three shapes ---
  ["edge", "placeholder-bare", "placeholder", :placeholder],
  ["edge", "placeholder-multiline", "placeholder\nssh-ed25519 #{ED7} x", :placeholder],
  ["edge", "placeholder-capital", "Placeholder — awaiting a key", :key_type],
  ["edge", "placeholder-after-blank", " placeholder — awaiting a key", :key_type],
  ["edge", "crlf-inside", "ssh-ed25519 #{ED7} a\r\nssh-ed25519 #{ED2} b", :multiline],
  ["edge", "lf-then-crlf", "ssh-ed25519 #{ED7} x\n\r\n", :multiline],
  ["edge", "cr-then-crlf", "ssh-ed25519 #{ED7} x\r\r\n", nil],
  ["edge", "only-crlf", "\r\n", :key_type],
  ["edge", "blanks-only", " \t ", :key_type],
  ["edge", "leading-tab", "\tssh-ed25519 #{ED7} tabbed", nil],
  ["edge", "vertical-tab-separator", "ssh-ed25519\v#{ED7}\vvt", nil],
  ["edge", "ecdsa-cert-type", "ecdsa-sha2-nistp256-cert-v01@openssh.com #{EC256} c", nil],
  ["edge", "sk-type-word", "sk-anything #{ED7} sk", nil],
  ["edge", "webauthn-type", "webauthn-sk-ecdsa-sha2-nistp256@openssh.com #{SK_EC} w", :key_type],
  ["edge", "uppercase-type", "SSH-ED25519 #{ED7} upper", :key_type],
  ["edge", "type-without-dash", "ssh #{ED7} x", :key_type],
].freeze

REASONS = {
  placeholder: "is a placeholder",
  multiline: "has more than one line",
  key_type: "does not start with a key type",
}.freeze

BEGIN_LINE = "# BEGIN ssh-keys-managed"
END_LINE = "# END ssh-keys-managed"
PEER = "ssh-ed25519 #{ED2} peer"
UNMANAGED = "ssh-ed25519 #{ED1} unmanaged"

# --- stub mitamae ---

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

  attr_reader :node, :files, :executes, :commands

  def initialize(home, ssm)
    @home = home
    @ssm = ssm
    @files = {}
    @executes = []
    @commands = []
    @node = { setup: { user: "fixture", group: "fixture", home: home, root: "#{home}/.setup" } }
  end

  def include_platform_cookbook(_name); end

  def require_external_auth(**_opts); end

  # Only the commands the recipe ran before the guard exist; anything else
  # (ssh-keygen, mktemp, rm, ...) raises.
  def run_command(command, **_opts)
    raise "unexpected command: #{command.inspect}" unless command.is_a?(String)

    @commands << command
    return Result.new("host-a\n", 0) if command == "hostname -s"

    name = command[/--name '([^']+)'/, 1]
    raise "unexpected command: #{command}" unless command.start_with?("aws ssm get-parameter") && name
    return Result.new("", 255) unless @ssm.key?(name)

    # aws ssm get-parameter --output text: the value plus one newline.
    Result.new("#{@ssm[name]}\n", 0)
  end

  def directory(_path, &block)
    ResourceRecorder.new.instance_eval(&block)
  end

  def execute(name, &block)
    rec = ResourceRecorder.new
    rec.instance_eval(&block)
    @executes << [name, rec.attrs]
  end

  def file(path, &block)
    rec = ResourceRecorder.new
    rec.instance_eval(&block)
    @files[path] = rec.attrs
  end
end

def path_of(device) = "/ssh-keys/devices/#{device}/public"

# Registry with host-a (the current device, no SSM keys) plus one client_only
# device per case. Devices in `absent` have no SSM public value.
def registry_for(cases, absent)
  devices = { "host-a" => { "ssh" => { "ssm_prefix" => "/ssh-keys/devices/host-a", "key_file" => "host_a_ed25519",
                                       "user" => "fixture" } } }
  ssm = {}
  cases.each do |device, value|
    devices[device] = { "client_only" => true, "ssh" => { "ssm_prefix" => "/ssh-keys/devices/#{device}" } }
    ssm[path_of(device)] = value unless absent.include?(device)
  end
  ssm["/host-registry/devices"] = JSON.generate("devices" => devices)
  ssm
end

# Evaluates a recipe source with __FILE__ = the real recipe path (so
# files/aws-config.json resolves). cases: [[device, value], ...].
def render(source, cases, absent: [], existing: nil, pve: false, dangling: false)
  MItamae.messages.clear
  Dir.mktmpdir("ssh-keys-test-") do |home|
    ssh = "#{home}/.ssh"
    auth = "#{ssh}/authorized_keys"
    Dir.mkdir(ssh) if existing || dangling
    File.write(auth, existing) if existing
    File.symlink("#{home}/missing-target", auth) if dangling
    RecipeFixture::File.pve_link = pve ? auth : nil
    fixture = RecipeFixture.new(home, registry_for(cases, absent))
    error = nil
    begin
      fixture.instance_eval(source, File.expand_path(DEFAULT_RECIPE))
    rescue StandardError => e
      error = e.class.name
    ensure
      RecipeFixture::File.pve_link = nil
    end
    target = pve ? "#{home}/.setup/ssh-keys/authorized_keys.staged" : auth
    # Paths are made relative to the temp home so two renders compare.
    rel = ->(s) { s.is_a?(String) ? s.gsub(home, "HOME") : s }
    files = fixture.files.to_h { |p, attrs| [rel.call(p), attrs.transform_values { |v| rel.call(v) }] }
    auth_attrs = files[rel.call(target)]
    warnings = MItamae.messages.select { |level, _| level == :warn }.map { |_, m| m }
                      .reject { |w| w.include?("/ssh-keys/devices/host-a/") } # host-a has no fixture keys
    return { content: auth_attrs && auth_attrs[:content], auth: auth_attrs, files: files,
             executes: fixture.executes.map { |n, a| [rel.call(n), a.transform_values { |v| rel.call(v) }] },
             warnings: warnings, commands: fixture.commands.map { |c| rel.call(c) }, error: error,
             auth_key: rel.call(target) }
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

  def info(msg)
    puts "INFO  [#{@label}] #{msg}" unless @quiet
  end
end

def shown(got, want) = got == want ? "" : " (got #{got.inspect[0, 200]}, want #{want.inspect[0, 200]})"

# Everything but the authorized_keys resource's `sensitive` must be equal.
def same_resources(head, base)
  strip_sensitive = ->(files) { files.transform_values { |a| a.reject { |k, _| k == :sensitive } } }
  strip_sensitive.call(head[:files]) == strip_sensitive.call(base[:files]) && head[:executes] == base[:executes] &&
    head[:error] == base[:error]
end

def skip_warning_checks(r, out, label, device, value, shape)
  path = path_of(device)
  named = out[:warnings].select { |w| w.include?(path) }
  r.check(named.length == 1, "#{label}: exactly one warning names #{path}#{shown(named.length, 1)}")
  ok = !named.empty? && named.all? { |w| w.include?(REASONS.fetch(shape)) }
  r.check(ok, "#{label}: the warning gives the #{shape} reason#{ok ? '' : " (got #{named.inspect[0, 300]})"}")
  pieces = value.split(/[\r\n\u0000]/).map(&:strip).select { |piece| piece.length > 12 }
  r.check(named.none? { |w| pieces.any? { |piece| w.include?(piece) } }, "#{label}: the warning does not print the value")
end

# One case alone: HEAD vs BASE (BASE without the value when HEAD skips it).
def solo_case(r, head, base, src, device, value, shape)
  label = "#{src} #{device}"
  h = render(head, [[device, value]])
  b = render(base, [[device, value]], absent: shape ? [device] : [])
  b_with = shape ? render(base, [[device, value]]) : b
  r.info("#{label}: shape=#{shape || 'kept'} main_writes=#{!b_with[:content].nil? && b_with[:content].include?(BEGIN_LINE)} " \
         "head_lines=#{h[:content] ? h[:content].lines.length : 0} main_lines=#{b_with[:content] ? b_with[:content].lines.length : 0}")
  if shape
    r.check(h[:content] == b[:content] && same_resources(h, b),
            "#{label}: skipped (#{shape}); output equals main without the value" + shown(h[:content], b[:content]))
    skip_warning_checks(r, h, label, device, value, shape)
  else
    r.check(h[:content] == b[:content] && same_resources(h, b),
            "#{label}: kept, byte-for-byte as main" + shown(h[:content], b[:content]))
    r.check(h[:warnings] == b[:warnings], "#{label}: same warnings as main" + shown(h[:warnings], b[:warnings]))
  end
  r.check(h[:commands] == b_with[:commands], "#{label}: runs exactly the commands main runs")
end

# A scenario with several devices / an existing file: HEAD vs BASE without the
# values HEAD skips.
def scenario(r, head, base, name, cases, **opts)
  skipped = cases.select { |_, _, shape| shape }
  h = render(head, cases.map { |d, v, _| [d, v] }, **opts)
  b = render(base, cases.map { |d, v, _| [d, v] }, absent: skipped.map(&:first), **opts)
  r.check(h[:content] == b[:content] && same_resources(h, b),
          "#{name}: byte-for-byte as main#{skipped.empty? ? '' : ' without the skipped values'}" +
          shown(h[:content], b[:content]))
  skipped.each { |device, value, shape| skip_warning_checks(r, h, name, device, value, shape) }
  base_named = b[:warnings].reject { |w| skipped.any? { |d, _, _| w.include?(path_of(d)) } }
  head_named = h[:warnings].reject { |w| skipped.any? { |d, _, _| w.include?(path_of(d)) } }
  r.check(head_named == base_named, "#{name}: no other warning than main's" + shown(head_named, base_named))
  [h, b]
end

def run_cases(label, head, base, quiet: false)
  r = Reporter.new(label, quiet)

  CASES.each { |src, device, value, shape| solo_case(r, head, base, src, device, value, shape) }

  # Every case in one registry: twins merge, dedup across cases, order kept.
  all = CASES.map { |_, device, value, shape| [device, value, shape] }
  h, = scenario(r, head, base, "all cases together", all)
  kept = CASES.count { |c| c[3].nil? }
  r.check(h[:content] && h[:content].include?("ssh-ed25519 #{ED3} twin-a,twin-b") &&
          h[:content].include?("ssh-ed25519 #{ED4} sh1@pro,twinc-b"), "all cases together: twin comments merged")
  r.info("all cases together: #{CASES.length} cases, #{kept} kept, #{CASES.length - kept} skipped " \
         "(#{REASONS.keys.map { |s| "#{s}=#{CASES.count { |c| c[3] == s }}" }.join(', ')})")

  # Existing managed blocks (earlier fixtures and rounds 1-3).
  hand = "ssh-ed25519 #{ED2} hand-added"
  [
    ["fixture existing block: tab-separated key + peer", ["ssh-ed25519\t#{ED5}\ttab-dev", nil]],
    ["fixture existing block: 4097-byte key + peer", [padded("ssh-ed25519 #{ED16} ", 4097), nil]],
    ["fixture existing block: rsa-sha2-256 key + peer", ["rsa-sha2-256 #{RSA2048} label-dev", :key_type]],
  ].each do |name, (line, shape)|
    existing = "#{hand}\n\n#{BEGIN_LINE}\n#{line}\n#{PEER}\n#{END_LINE}\n"
    scenario(r, head, base, name, [["dev", line, shape], ["peer", PEER, nil]], existing: existing)
  end
  r1_existing = "# unmanaged comment\n\n#{BEGIN_LINE}\nssh-ed25519\t#{R1_ONE}\tfixture\n" \
                "ssh-ed25519 #{R1_TWO} peer\n#{END_LINE}\n"
  scenario(r, head, base, "r1 existing-block-all-invalid", [["invalid", "placeholder", :placeholder]],
           existing: r1_existing)
  scenario(r, head, base, "r1 existing-block-mixed-tab-and-valid-peer",
           [["candidate", "ssh-ed25519\t#{R1_ONE}\tfixture", nil], ["peer", "ssh-ed25519 #{R1_TWO} peer", nil]],
           existing: r1_existing)
  r2_existing = ->(line) { [UNMANAGED, "", BEGIN_LINE, line, PEER, END_LINE, ""].join("\n") }
  tab = "ssh-ed25519\t#{ED5}\tfixture"
  scenario(r, head, base, "r2 mixed-tab-and-peer", [["tab", tab, nil], ["peer", PEER, nil]],
           existing: r2_existing.call(tab))
  long = padded("#{R2_BASE} ", 4097, "x")
  scenario(r, head, base, "r2 mixed-long-and-peer", [["long", long, nil], ["peer", PEER, nil]],
           existing: r2_existing.call(long))
  rsa_label = "rsa-sha2-256 #{RSA2048} fixture"
  scenario(r, head, base, "r2 mixed-rsa-label-and-peer", [["rsa-label", rsa_label, :key_type], ["peer", PEER, nil]],
           existing: r2_existing.call(rsa_label))
  old = [BEGIN_LINE, "fixture-retired-value", END_LINE, ""].join("\n")
  scenario(r, head, base, "r2 all-skipped", [["empty", "placeholder — awaiting a public key", :placeholder]],
           existing: old)
  limit = padded("#{R2_BASE} ", 4096, "x")
  scenario(r, head, base, "r2 merge-near-limit", [["primary", limit, nil], ["secondary", limit, nil]])
  [false, true].each do |pve|
    out, = scenario(r, head, base, "r2 file-resource pve=#{pve}", [["peer", PEER, nil]], existing: old, pve: pve)
    r.check(out[:auth] && out[:auth][:sensitive] == true,
            "r2 file-resource pve=#{pve}: the authorized_keys #{pve ? 'staging ' : ''}file resource is sensitive")
  end
  pve_skip, = scenario(r, head, base, "PVE staging with a skipped value",
                       [["peer", PEER, nil], ["opt", "restrict #{PEER}", :key_type]], pve: true)
  deploys = pve_skip[:executes].count { |n, _| n.start_with?("deploy authorized_keys to pmxcfs") }
  r.check(deploys == 1, "PVE staging with a skipped value: one pmxcfs deploy execute#{shown(deploys, 1)}")
  dangling, = scenario(r, head, base, "r2 dangling-authorized-keys", [["peer", PEER, nil]], dangling: true)
  r.check(dangling[:error] == "Errno::ENOENT", "r2 dangling-authorized-keys: same Errno::ENOENT as main" +
          shown(dangling[:error], "Errno::ENOENT"))
  %w[r3-comment-is-another-public-key r3-hostname-prefix r3-bare-option r3-comment-line r3-bare-openssh-certificate
     r3-non-key-ascii-text r3-valid-blob-with-shell-punctuation-comment].each do |device|
    _, _, value, shape = CASES.find { |c| c[1] == device }
    scenario(r, head, base, "r3 #{device} in an existing block + peer", [[device, value, shape], ["peer", PEER, nil]],
             existing: r2_existing.call(value))
  end
  r.failures
end

def base_source
  show = ->() { Open3.capture2e("git", "-C", REPO, "show", "#{BASE_REF}:#{RECIPE_IN_REPO}") }
  out, status = show.call
  if !status.success? && BASE_REF =~ /\A\h{40}\z/
    # Shallow CI checkout: fetch just that commit.
    Open3.capture2e("git", "-C", REPO, "fetch", "--no-tags", "--depth=1", "origin", BASE_REF)
    out, status = show.call
  end
  status.success? ? out : nil
end

recipe = File.expand_path(ARGV[0] || DEFAULT_RECIPE)
head = File.read(recipe)
base = base_source
unless base
  msg = "BASE recipe #{BASE_REF}:#{RECIPE_IN_REPO} not available; nothing compared"
  if REQUIRE_BASE
    puts "FAIL  #{msg} (REQUIRE_BASE_RECIPE=1)"
    puts "FAILED: 1"
    exit 1
  end
  puts "SKIP  #{msg}"
  exit 0
end
puts "INFO  HEAD=#{recipe} BASE=#{BASE_REF}:#{RECIPE_IN_REPO}"
failures = run_cases("head-vs-main", head, base)

if recipe == File.expand_path(DEFAULT_RECIPE)
  guard = /^  skip_reason = public_value_skip_reason\.call\(raw_pub\)\n  if skip_reason\n.*?^    next\n  end\n/m
  sensitive = "      # The old content (possibly a value a previous run should not have\n" \
              "      # distributed) would otherwise be printed in mitamae's file diff.\n" \
              "      sensitive true\n"
  mutants = {
    "negative: guard removed" => head.sub(guard, ""),
    "negative: placeholder check removed" => head.sub(/^  return "is a placeholder".*\n/, ""),
    "negative: line check removed" => head.sub(/^  return "has more than one line".*\n/, ""),
    "negative: key-type check removed" => head.sub(/^  return "does not start with a key type.*\n/, ""),
    "negative: authorized_keys files not sensitive" => head.gsub(sensitive, ""),
    "negative: value written unstripped" => head.sub("  pub_line = raw_pub.strip\n", "  pub_line = raw_pub\n"),
  }
  mutants.each do |name, mutant|
    if mutant == head
      failures += 1
      puts "FAIL  [#{name}] could not build the mutant from #{recipe} (pattern drifted)"
      next
    end
    mutant_failures = run_cases(name, mutant, base, quiet: true)
    ok = mutant_failures.positive?
    failures += 1 unless ok
    puts "#{ok ? 'PASS' : 'FAIL'}  [#{name}] the mutant fails #{mutant_failures} assertion(s)"
  end
end

puts(failures.positive? ? "FAILED: #{failures}" : "OK")
exit(failures.positive? ? 1 : 0)
