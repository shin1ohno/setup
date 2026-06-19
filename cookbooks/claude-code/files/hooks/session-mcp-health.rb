#!/usr/bin/env ruby
# frozen_string_literal: true

# SessionStart hook: detect unreachable LOCAL MCP servers and, when a real
# (non-cold-start) fault is found, inject a directive telling Claude to run the
# `mcp-doctor` skill in AUTO mode. Stays completely silent when healthy so it
# adds no context noise to normal sessions.
#
# Scope: only the auto-fixable local-Docker MCP class — endpoints of the form
# http://127.0.0.1:<port>/mcp in ~/.claude.json. Hosted-server auth (socrates /
# Looker) is NOT observable from a shell, so it is verified by the skill itself
# once summoned; the hook does not summon for auth alone.
#
# Host-tolerant: Macs without Docker, or without the local-mcp stack, exit
# silently (this cookbook ships to several Macs).
#
# Wedge signal: a live MCP server answers any HTTP status (200/406/...). The
# Docker Desktop port-forward wedge gives connection-refused -> curl http_code
# "000". So "up" == "got a non-000 HTTP code".

require "json"
require "open3"

HOME = ENV["HOME"].to_s
CLAUDE_JSON = File.join(HOME, ".claude.json")
SENTINEL = File.join(HOME, ".claude", "state", "mcp-doctor-last-restart")
PROBE_TIMEOUT = 4   # seconds per endpoint
COOLDOWN_MINS = 10  # suppress repeat Docker Desktop restarts within this window

def sh(*args)
  out, _err, st = Open3.capture3(*args)
  [out, st.success?]
rescue SystemCallError
  ["", false]
end

# Local MCP endpoints (http://127.0.0.1:<port>/...) from global mcpServers.
def local_mcp_endpoints
  return [] unless File.exist?(CLAUDE_JSON)

  data = JSON.parse(File.read(CLAUDE_JSON))
  servers = data["mcpServers"] || {}
  servers.filter_map do |name, cfg|
    url = cfg["url"].to_s
    next unless url =~ %r{\Ahttp://127\.0\.0\.1:(\d+)/}

    { name: name, url: url, port: Regexp.last_match(1) }
  end
rescue JSON::ParserError, SystemCallError
  []
end

# "up" == connection established AND an HTTP status came back (non-000).
def endpoint_up?(url)
  out, _ok = sh("curl", "-sS", "-m", PROBE_TIMEOUT.to_s,
                "-o", "/dev/null", "-w", "%{http_code}", url)
  code = out.strip
  !code.empty? && code != "000"
end

def docker_available?
  _out, ok = sh("docker", "info", "--format", "{{.ServerVersion}}")
  ok
end

# Any local-mcp container started within the cold-start window? Such a
# container legitimately refuses connections for tens of seconds while booting
# (cognee-mcp waits on cognee health, then inits the MCP server).
def warming_up?
  out, ok = sh("docker", "ps", "--filter", "name=local-mcp",
               "--format", "{{.RunningFor}}")
  return false unless ok

  out.lines.any? { |line| line =~ /second|Less than/i }
end

def cooldown_active?
  out, _ok = sh("find", SENTINEL, "-mmin", "-#{COOLDOWN_MINS}")
  !out.strip.empty?
end

endpoints = local_mcp_endpoints
exit 0 if endpoints.empty? # no local MCP configured -> nothing to check

down = endpoints.reject { |e| endpoint_up?(e[:url]) }
exit 0 if down.empty? # all local MCP reachable -> silent

# A local endpoint is down. Decide whether it is actionable on this host.
exit 0 unless docker_available? # not a Docker host -> cannot auto-fix, stay quiet
exit 0 if warming_up?           # container still booting -> not a real fault

names = down.map { |e| "#{e[:name]} (port #{e[:port]})" }.join(", ")
cooldown_note =
  if cooldown_active?
    "COOLDOWN ACTIVE: a Docker Desktop restart occurred within the last " \
      "#{COOLDOWN_MINS} minutes. Do NOT restart Docker Desktop again — report " \
      "current state and wait for it to settle instead."
  else
    ""
  end

puts <<~MSG
  [session-start MCP health] LOCAL MCP server(s) not responding: #{names}.

  ACTION REQUIRED — run the `mcp-doctor` skill now in AUTO mode. The user has
  pre-approved fully-automatic repair (including a Docker Desktop restart, which
  briefly stops all containers). Work the Docker Desktop port-forward wedge
  ladder, fix, and verify each endpoint returns a 200 MCP `initialize` before
  continuing. Also verify socrates auth (mcp__socrates__auth_status) in the same
  sweep.
  #{cooldown_note}
MSG
