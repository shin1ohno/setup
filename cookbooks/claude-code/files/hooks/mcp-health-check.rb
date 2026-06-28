#!/usr/bin/env ruby
# frozen_string_literal: true

# SessionStart hook: report claude.ai MCP connector health (auth / connection)
# and, when any connector needs (re)authentication, inject a reminder into the
# session context so Claude invokes the mcp-auth skill. This hook DETECTS +
# REPORTS only — OAuth login is interactive (browser + localhost callback) and
# cannot complete in a non-interactive hook shell, so the actual
# `claude mcp login` is deferred to the mcp-auth skill.
#
# Latency: `claude mcp list` health-pings every server and takes ~8-15s on this
# setup — far too long to run synchronously on every session start (and a tight
# `timeout` would just get the command killed, masking real status). So the hook
# is STALE-WHILE-REVALIDATE: it reports the cached verdict instantly (zero
# startup delay) and, when the cache is stale, refreshes it in a fully detached
# background child (`--refresh`) for the next start. Trade-off: a newly-expired
# token is reported one session late; for an immediate fresh check, invoke the
# mcp-auth skill (it checks synchronously on demand).
#
# Notes:
# - `claude` is NOT on the non-interactive hook PATH (ruby-shim adds only rbenv
#   + mise shims), so the binary is resolved explicitly below.
# - Classify on the TEXT LABEL, not the ✔/✓ glyph (glyph bytes are font/version
#   dependent).
# - Never exit non-zero and never raise: a hook failure must not disturb the
#   session. All failure paths fall through to silent exit 0.
# - Test seams: MCP_HEALTH_FIXTURE_FILE (parse file contents instead of running
#   `claude mcp list`, synchronously) and MCP_HEALTH_CACHE_FILE (override the
#   cache path) keep tests from touching live auth or the production cache.

require "json"
require "open3"
require "rbconfig"

CACHE_PATH      = ENV["MCP_HEALTH_CACHE_FILE"] || File.join(Dir.home, ".claude", ".mcp-health-cache.json")
CACHE_TTL       = 300 # seconds — skip a background refresh within this window
REFRESH_TIMEOUT = 30  # seconds — hard cap on the background `claude mcp list`

def resolve_claude
  candidate = File.join(Dir.home, ".local", "bin", "claude")
  return candidate if File.executable?(candidate)

  which = `command -v claude 2>/dev/null`.to_s.strip
  which.empty? ? nil : which
end

# Raw `claude mcp list` text, or nil on failure/timeout. A fixture file (tests)
# short-circuits the live call.
def fetch_list(claude_bin)
  fixture = ENV["MCP_HEALTH_FIXTURE_FILE"]
  return File.read(fixture) if fixture && File.exist?(fixture)
  return nil unless claude_bin

  out, _err, status = Open3.capture3("timeout", REFRESH_TIMEOUT.to_s, claude_bin, "mcp", "list")
  status.success? ? out : nil
rescue StandardError
  nil
end

# Parse a `claude mcp list` body into [{name, status}], classifying by the
# trailing text label. A status line looks like: "name: url - STATUS".
def classify(text)
  text.each_line.filter_map do |line|
    line = line.chomp
    next unless line.include?(" - ")

    name        = line.split(":", 2).first.to_s.strip
    status_text = line.rpartition(" - ").last.strip
    next if name.empty? || status_text.empty?

    s = status_text.downcase
    klass =
      if    s.include?("needs authentication") then "NEEDS-AUTH"
      elsif s.include?("pending approval")      then "PENDING"
      elsif s.include?("tools fetch failed")    then "DEGRADED"
      elsif s.include?("connected")             then "CONNECTED"
      elsif s.include?("failed to connect") || s.include?("connection error") then "DOWN"
      else "UNKNOWN"
      end

    { "name" => name, "status" => klass }
  end
end

def cache_fresh?
  File.exist?(CACHE_PATH) && (Time.now - File.mtime(CACHE_PATH)) < CACHE_TTL
rescue StandardError
  false
end

def read_cache
  JSON.parse(File.read(CACHE_PATH))["results"]
rescue StandardError
  nil
end

def write_cache(results)
  dir = File.dirname(CACHE_PATH)
  Dir.mkdir(dir) unless File.directory?(dir)
  File.write(CACHE_PATH, JSON.generate("checked_at" => Time.now.to_i, "results" => results))
rescue StandardError
  nil # cache is best-effort
end

# Refresh the cache from a live `claude mcp list`. Used by --refresh and tests.
def refresh_cache
  text = fetch_list(resolve_claude)
  write_cache(classify(text)) unless text.nil?
end

# Spawn a fully detached child that refreshes the cache for the NEXT start.
def spawn_background_refresh
  return unless resolve_claude

  pid = Process.spawn(
    RbConfig.ruby, File.expand_path(__FILE__), "--refresh",
    in: File::NULL, out: File::NULL, err: File::NULL, pgroup: true,
  )
  Process.detach(pid)
rescue StandardError
  nil
end

# Emit the SessionStart additionalContext JSON iff something needs attention.
def emit(results)
  return if results.nil?

  attention = results.select { |r| %w[NEEDS-AUTH PENDING DOWN].include?(r["status"]) }
  return if attention.empty? # all healthy → stay silent, do not bloat context

  by    = ->(k) { attention.select { |r| r["status"] == k }.map { |r| r["name"] } }
  parts = []
  parts << "NEEDS-AUTH: #{by.call('NEEDS-AUTH').join(', ')}"               unless by.call("NEEDS-AUTH").empty?
  parts << "PENDING approval (run /mcp): #{by.call('PENDING').join(', ')}" unless by.call("PENDING").empty?
  parts << "DOWN (transient): #{by.call('DOWN').join(', ')}"              unless by.call("DOWN").empty?

  msg = "MCP connectors need attention — #{parts.join(' | ')}. " \
        "Invoke the mcp-auth skill to re-authenticate the NEEDS-AUTH servers " \
        "(it runs `claude mcp login <name>` and walks the browser flow). " \
        "Status is from the last check (stale-while-revalidate); the skill re-checks live. " \
        "This reflects `claude mcp list` only; notion/plugin connectors are checked by the skill."

  puts JSON.generate(
    "hookSpecificOutput" => {
      "hookEventName"     => "SessionStart",
      "additionalContext" => msg,
    },
  )
end

def main
  # Background refresh worker (spawned by spawn_background_refresh).
  if ARGV.include?("--refresh")
    refresh_cache
    return
  end

  # Test seam: fixture mode runs synchronously so the parser is observable.
  if ENV["MCP_HEALTH_FIXTURE_FILE"]
    text = fetch_list(resolve_claude)
    return if text.nil?

    results = classify(text)
    write_cache(results)
    emit(results)
    return
  end

  # Real path: report the cached verdict instantly, refresh in the background
  # if stale. `claude mcp list` never runs in the foreground here.
  emit(read_cache)
  spawn_background_refresh unless cache_fresh?
end

main
