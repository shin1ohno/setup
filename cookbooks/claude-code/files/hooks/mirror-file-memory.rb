#!/usr/bin/env ruby
# frozen_string_literal: true

# Mirror the harness-native file memory (~/.claude/projects/<slug>/memory/*.md)
# into a memory-v2 MCP store, so the same knowledge is reachable both from the
# auto-loaded MEMORY.md index AND from `recall` / the box's autonomous agents.
#
# Modes:
#   (no args)              PostToolUse hook. stdin carries the tool payload; the
#                          written file is mirrored when it is a memory note.
#   --sweep [--dry-run]    Reconcile every memory note under the projects dir.
#                          Registered on SessionStart; also the one-time import.
#
# Why a script and not the MCP tools: the write must not depend on the session's
# MCP client (a) because a hook has no access to it, and (b) because that client
# is the component that breaks — 2026-08-17 it answered every
# `mcp__memory-work__*` call with `DCR rejected (HTTP 401) invalid_token` while
# raw JSON-RPC against the same endpoint with the same headersHelper token
# worked. This path talks to the server directly.
#
# Primitive is `ingest`, not `remember`: ingest upserts by (dataset, doc_key), so
# a re-run supersedes its own previous version instead of piling up duplicates,
# and it does not depend on the keeper/reconciler (not deployed on the box —
# `memory_stats` shows a standing `raw_backlog`).
#
# Config — ~/.claude/memory-mirror.json:
#   {"server": "memory-work", "dataset": "file-memory", "enabled": true}
#   Absent or enabled:false => silent no-op. The public cookbook ships NO config
#   (so the hook is inert on hosts without a store); the work overlay drops one.
#   `server` must name an mcpServers entry in ~/.claude.json with an http url;
#   its `headersHelper` (when present) supplies the Authorization header.
#
# State — ~/.claude/memory-mirror-state.json: doc_key => {sha256, doc_id, ...}.
#   sha match => no HTTP at all (a steady-state sweep sends nothing). A state
#   entry whose file has disappeared => forget(doc_id), so deletions propagate.
#
# Never disturbs the session: every failure path logs one line to
# ~/.claude/memory-mirror.log and exits 0.

require "digest"
require "fileutils"
require "json"
require "net/http"
require "open3"
require "socket"
require "uri"

HOME         = Dir.home
CONFIG_PATH  = ENV["MEMORY_MIRROR_CONFIG"]       || File.join(HOME, ".claude", "memory-mirror.json")
STATE_PATH   = ENV["MEMORY_MIRROR_STATE"]        || File.join(HOME, ".claude", "memory-mirror-state.json")
LOCK_PATH    = ENV["MEMORY_MIRROR_LOCK"]         || File.join(HOME, ".claude", "memory-mirror.lock")
LOG_PATH     = ENV["MEMORY_MIRROR_LOG"]          || File.join(HOME, ".claude", "memory-mirror.log")
CLAUDE_JSON  = ENV["MEMORY_MIRROR_CLAUDE_JSON"]  || File.join(HOME, ".claude.json")
PROJECTS_DIR = ENV["MEMORY_MIRROR_PROJECTS_DIR"] || File.join(HOME, ".claude", "projects")
HOSTNAME     = ENV["MEMORY_MIRROR_HOST"]         || Socket.gethostname.to_s.split(".").first

INDEX_BASENAME = "MEMORY.md"
MAX_BYTES      = 512 * 1024 # a memory note is a few KB; anything larger is not one
OPEN_TIMEOUT   = 2
READ_TIMEOUT   = 20
HELPER_TIMEOUT = 10

def log(level, msg)
  FileUtils.mkdir_p(File.dirname(LOG_PATH))
  File.open(LOG_PATH, "a") { |f| f.puts("#{Time.now.utc.strftime('%FT%TZ')} #{level} #{msg}") }
rescue StandardError
  nil
end

# --- config / server resolution ---------------------------------------------

def load_config
  return nil unless File.exist?(CONFIG_PATH)

  cfg = JSON.parse(File.read(CONFIG_PATH))
  return nil unless cfg["enabled"] == true
  return nil if cfg["server"].to_s.empty?

  { "server" => cfg["server"], "dataset" => cfg["dataset"].to_s.empty? ? "file-memory" : cfg["dataset"] }
rescue StandardError => e
  log("WARN", "config unreadable (#{CONFIG_PATH}): #{e.class}: #{e.message}")
  nil
end

# The endpoint and its auth are read from the live MCP registration rather than
# hardcoded, so this stays generic across hosts (and follows the store if its
# port or audience changes).
def resolve_server(name)
  entry = JSON.parse(File.read(CLAUDE_JSON)).dig("mcpServers", name)
  raise "no mcpServers entry named #{name.inspect}" if entry.nil?

  url = entry["url"].to_s
  raise "server #{name} has no url" if url.empty?

  headers = {}
  helper = entry["headersHelper"].to_s
  unless helper.empty?
    out, status = with_timeout(HELPER_TIMEOUT) { Open3.capture2(helper) }
    raise "headersHelper #{helper} exited #{status.exitstatus}" unless status.success?

    parsed = JSON.parse(out)
    raise "headersHelper #{helper} did not emit a JSON object" unless parsed.is_a?(Hash)

    parsed.each { |k, v| headers[k.to_s] = v.to_s }
  end

  { url: url, headers: headers }
end

def with_timeout(seconds)
  # Timeout.timeout cannot interrupt a blocking waitpid on every ruby build, so
  # the helper is fenced by its own alarm-free guard: run it in a thread and give
  # up on the result if it overruns (the child is short-lived curl).
  thread = Thread.new { yield }
  raise "timed out after #{seconds}s" unless thread.join(seconds)

  thread.value
end

# --- MCP client (stateful streamable HTTP, SSE-framed responses) -------------

class McpClient
  PROTOCOL = "2025-06-18"

  def initialize(url, headers)
    @uri = URI.parse(url)
    @headers = headers
    @id = 0
  end

  def call(tool, arguments)
    ensure_session
    msg = post(jsonrpc("tools/call", { "name" => tool, "arguments" => arguments }, id: true))
    raise "#{tool}: #{msg['error']}" if msg["error"]

    result = msg["result"] || {}
    raise "#{tool}: isError #{result.dig('content', 0, 'text')}" if result["isError"]

    text = result.dig("content", 0, "text")
    return result if text.nil?

    begin
      JSON.parse(text)
    rescue JSON::ParserError
      text
    end
  end

  private

  def ensure_session
    return @session if @session

    body = jsonrpc("initialize", {
      "protocolVersion" => PROTOCOL,
      "capabilities" => {},
      "clientInfo" => { "name" => "memory-mirror", "version" => "1" },
    }, id: true)

    response = request(body)
    raise "initialize HTTP #{response.code}" unless response.code.to_i == 200

    @session = response["mcp-session-id"].to_s
    raise "initialize returned no mcp-session-id" if @session.empty?

    request(jsonrpc("notifications/initialized", nil))
    @session
  end

  def jsonrpc(method, params, id: false)
    body = { "jsonrpc" => "2.0", "method" => method }
    body["id"] = (@id += 1) if id
    body["params"] = params unless params.nil?
    body
  end

  def post(body)
    response = request(body)
    raise "#{body['method']} HTTP #{response.code}: #{response.body.to_s[0, 200]}" unless response.code.to_i == 200

    parse_payload(response.body)
  end

  def request(body)
    http = Net::HTTP.new(@uri.host, @uri.port)
    http.use_ssl = (@uri.scheme == "https")
    http.open_timeout = OPEN_TIMEOUT
    http.read_timeout = READ_TIMEOUT

    req = Net::HTTP::Post.new(@uri.request_uri)
    @headers.each { |k, v| req[k] = v }
    req["content-type"] = "application/json"
    req["accept"] = "application/json, text/event-stream"
    req["mcp-session-id"] = @session if @session
    req.body = JSON.generate(body)

    http.start { |conn| conn.request(req) }
  end

  # Responses come back SSE-framed (`event: message` / `data: {...}`); a plain
  # JSON body is accepted too so this does not depend on the framing choice.
  def parse_payload(raw)
    text = raw.to_s
    candidates = text.lines.select { |l| l.start_with?("data:") }.map { |l| l.sub(/\Adata:\s*/, "") }
    candidates = [text] if candidates.empty?

    candidates.reverse_each do |chunk|
      begin
        parsed = JSON.parse(chunk)
      rescue JSON::ParserError
        next
      end
      return parsed if parsed.is_a?(Hash) && (parsed.key?("result") || parsed.key?("error"))
    end

    raise "unparsable response: #{text[0, 200]}"
  end
end

# --- memory-note identification --------------------------------------------

# Returns "<project-slug>/<basename>" for a memory note, nil for anything else.
def memory_note(path)
  return nil if path.to_s.empty?

  full = File.expand_path(path)
  root = File.expand_path(PROJECTS_DIR)
  return nil unless full.start_with?(root + File::SEPARATOR)

  parts = full[(root.length + 1)..].split(File::SEPARATOR)
  return nil unless parts.length == 3 && parts[1] == "memory"
  return nil unless parts[2].end_with?(".md")
  return nil if parts[2] == INDEX_BASENAME

  "#{parts[0]}/#{parts[2]}"
end

def doc_key(rel)
  slug, basename = rel.split("/", 2)
  "#{HOSTNAME}/#{slug}/#{File.basename(basename, '.md')}"
end

def document_for(path, rel)
  slug, = rel.split("/", 2)
  header = "<!-- claude-file-memory mirror -->\n" \
           "project: #{slug}\n" \
           "source_host: #{HOSTNAME}\n" \
           "source_path: #{path}\n\n"
  header + File.read(path)
end

def note_paths
  Dir.glob(File.join(PROJECTS_DIR, "*", "memory", "*.md")).select { |p| memory_note(p) }.sort
end

# --- state ------------------------------------------------------------------

def read_state
  return {} unless File.exist?(STATE_PATH)

  parsed = JSON.parse(File.read(STATE_PATH))
  parsed.is_a?(Hash) ? parsed : {}
rescue StandardError
  {}
end

def write_state(state)
  FileUtils.mkdir_p(File.dirname(STATE_PATH))
  tmp = "#{STATE_PATH}.tmp"
  File.write(tmp, JSON.pretty_generate(state) + "\n")
  File.rename(tmp, STATE_PATH)
rescue StandardError => e
  log("WARN", "state write failed: #{e.class}: #{e.message}")
end

# One run at a time. A hook that loses the race exits immediately — the
# SessionStart sweep picks the file up, so nothing is lost by not waiting.
def with_lock
  FileUtils.mkdir_p(File.dirname(LOCK_PATH))
  File.open(LOCK_PATH, File::RDWR | File::CREAT, 0o600) do |f|
    unless f.flock(File::LOCK_EX | File::LOCK_NB)
      log("INFO", "another mirror run holds the lock; deferring to the next sweep")
      return nil
    end

    yield
  end
end

# --- operations -------------------------------------------------------------

def mirror_one(client, dataset, path, rel, state)
  body = File.read(path)
  if body.bytesize > MAX_BYTES
    log("WARN", "skipped #{path}: #{body.bytesize} bytes exceeds #{MAX_BYTES}")
    return :skipped
  end

  key = doc_key(rel)
  sha = Digest::SHA256.hexdigest(body)
  return :unchanged if state.dig(key, "sha256") == sha

  result = client.call("ingest", {
    "document" => document_for(path, rel),
    "dataset" => dataset,
    "doc_key" => key,
  })
  doc_id = result.is_a?(Hash) ? result["doc_id"] : nil

  state[key] = {
    "sha256" => sha,
    "doc_id" => doc_id,
    "source_path" => path,
    "mirrored_at" => Time.now.utc.strftime("%FT%TZ"),
  }
  log("INFO", "mirrored #{key} (doc_id=#{doc_id})")
  :mirrored
end

def forget_one(client, key, entry, state)
  doc_id = entry.is_a?(Hash) ? entry["doc_id"] : nil
  if doc_id.to_s.empty?
    log("WARN", "cannot forget #{key}: state has no doc_id; dropping the entry")
    state.delete(key)
    return :dropped
  end

  client.call("forget", { "id" => doc_id })
  state.delete(key)
  log("INFO", "forgot #{key} (doc_id=#{doc_id}) — source file is gone")
  :forgotten
end

def stale_keys(state, live_keys)
  state.keys.select { |k| k.start_with?("#{HOSTNAME}/") && !live_keys.include?(k) }
end

def sweep(config, dry_run:)
  paths = note_paths
  state = read_state
  live = {}
  paths.each { |p| live[doc_key(memory_note(p))] = p }
  gone = stale_keys(state, live.keys)
  changed = paths.reject { |p| state.dig(doc_key(memory_note(p)), "sha256") == Digest::SHA256.hexdigest(File.read(p)) }

  if dry_run
    puts "dataset: #{config['dataset']}  server: #{config['server']}  host: #{HOSTNAME}"
    puts "notes: #{paths.length}  to-ingest: #{changed.length}  unchanged: #{paths.length - changed.length}  to-forget: #{gone.length}"
    changed.each { |p| puts "  ingest  #{doc_key(memory_note(p))}  <- #{p}" }
    gone.each    { |k| puts "  forget  #{k}" }
    return 0
  end

  # Steady state: return before resolving the server, so a session start does not
  # mint an auth token (and hit the metadata server) for nothing.
  if changed.empty? && gone.empty?
    log("INFO", "sweep: #{paths.length} notes, all up to date")
    return 0
  end

  server = resolve_server(config["server"])
  client = McpClient.new(server[:url], server[:headers])
  counts = { mirrored: 0, unchanged: paths.length - changed.length, skipped: 0, forgotten: 0, dropped: 0, failed: 0 }

  changed.each do |path|
    rel = memory_note(path)
    begin
      counts[mirror_one(client, config["dataset"], path, rel, state)] += 1
    rescue StandardError => e
      counts[:failed] += 1
      log("WARN", "mirror failed for #{path}: #{e.class}: #{e.message}")
    end
  end

  gone.each do |key|
    begin
      counts[forget_one(client, key, state[key], state)] += 1
    rescue StandardError => e
      counts[:failed] += 1
      log("WARN", "forget failed for #{key}: #{e.class}: #{e.message}")
    end
  end

  write_state(state)
  summary = counts.map { |k, v| "#{k}=#{v}" }.join(" ")
  warn "memory-mirror sweep: #{summary}"
  log("INFO", "sweep #{summary}")

  if counts[:failed] > 0
    puts JSON.generate(
      "hookSpecificOutput" => {
        "hookEventName" => "SessionStart",
        "additionalContext" => "file-memory mirror: #{counts[:failed]} note(s) failed to reach the " \
                               "#{config['server']} store (#{summary}). See #{LOG_PATH}. Knowledge saved " \
                               "to ~/.claude/projects/*/memory/ is NOT searchable via recall until this clears.",
      },
    )
  end
  counts[:failed]
end

def hook
  payload = JSON.parse($stdin.read)
  path = payload.dig("tool_input", "file_path").to_s
  rel = memory_note(path)
  return if rel.nil?

  config = load_config
  return if config.nil?

  with_lock do
    state = read_state
    server = resolve_server(config["server"])
    client = McpClient.new(server[:url], server[:headers])

    if File.exist?(path)
      mirror_one(client, config["dataset"], path, rel, state)
    else
      key = doc_key(rel)
      forget_one(client, key, state[key], state) if state.key?(key)
    end

    write_state(state)
  end
end

def main
  if ARGV.include?("--sweep")
    config = load_config
    if config.nil?
      log("INFO", "sweep skipped: no enabled config at #{CONFIG_PATH}")
      return
    end

    with_lock { sweep(config, dry_run: ARGV.include?("--dry-run")) }
  else
    hook
  end
end

begin
  main
rescue StandardError => e
  # JSON::ParserError (a bad hook payload) is a StandardError too, so this single
  # clause covers it — a hook must never raise into the session.
  log("WARN", "#{e.class}: #{e.message}")
end

exit 0
