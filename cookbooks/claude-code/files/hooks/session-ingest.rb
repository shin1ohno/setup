#!/usr/bin/env ruby
# frozen_string_literal: true

# Stop / SessionEnd hook: hand the session's transcript to the session-search
# shipper (`ccs ingest`) without blocking Claude Code.
#
# This is component C4 of docs/design/claude-session-search.md (§6.4, payload
# §7.3). The hook only starts the shipper; parsing, masking, sending, the lock
# and the cursor all live in `ccs`. The sweep timer (C5) catches every session
# this hook misses, so a skipped spawn is a latency loss, never a data loss —
# which is why every doubtful input below exits quietly instead of guessing.
#
# Contract with Claude Code:
#   - reads only `transcript_path` and `session_id` from the stdin payload;
#   - never writes to stdout (a Stop hook's stdout can be fed back to the
#     model) and never exits non-zero;
#   - returns in well under 50 ms: `ccs` is spawned in its own process group
#     with stdin closed and stdout/stderr on the log, then detached.
#
# Skips without spawning (exit 0): malformed JSON, no `transcript_path`, a path
# that is not an existing regular `*.jsonl` file under ~/.claude/projects/
# (resolved through symlinks and `..`), and no `ccs` binary. Only the missing
# binary is logged — the other cases are normal for hook payloads that do not
# describe a stored session.
#
# `ccs` is looked up at ~/.local/bin/ccs first (where cookbooks/session-search
# installs it), then on PATH. Log: ~/.claude/session-search.log, shared with
# `ccs` itself, whose output the spawned process appends to it.
#
# settings.json runs this hook as `ruby-shim --disable-gems session-ingest.rb`:
# loading RubyGems costs about 60 ms of interpreter start, more than the whole
# 50 ms budget, and the hook needs nothing beyond the stdlib (json is a default
# library and loads without RubyGems). Keep it that way — no gem requires.

require "json"

module SessionIngestHook
  module_function

  def home
    Dir.home
  end

  def log_path
    File.join(home, ".claude", "session-search.log")
  end

  def log(message, session_id = nil)
    sid = session_id.is_a?(String) && !session_id.empty? ? " session=#{session_id}" : ""
    File.open(log_path, "a") do |f|
      f.puts("#{Time.now.utc.strftime("%Y-%m-%dT%H:%M:%SZ")} session-ingest#{sid}: #{message}")
    end
  rescue StandardError
    nil
  end

  # The resolved transcript path when it is a regular *.jsonl file inside
  # ~/.claude/projects/, otherwise nil.
  def transcript(raw)
    return nil unless raw.is_a?(String) && !raw.empty?
    return nil unless raw.end_with?(".jsonl")

    root = File.realpath(File.join(home, ".claude", "projects"))
    path = File.realpath(File.expand_path(raw))
    return nil unless path.start_with?("#{root}/")
    return nil unless path.end_with?(".jsonl")
    return nil unless File.file?(path)

    path
  rescue SystemCallError
    nil
  end

  def executable?(path)
    File.file?(path) && File.executable?(path)
  end

  def find_ccs
    local = File.join(home, ".local", "bin", "ccs")
    return local if executable?(local)

    ENV.fetch("PATH", "").split(File::PATH_SEPARATOR).each do |dir|
      next if dir.empty?

      candidate = File.join(dir, "ccs")
      return candidate if executable?(candidate)
    end
    nil
  end

  def run(stdin)
    payload = JSON.parse(stdin)
    return unless payload.is_a?(Hash)

    session_id = payload["session_id"]
    path = transcript(payload["transcript_path"])
    return unless path

    ccs = find_ccs
    unless ccs
      log("ccs not found (~/.local/bin/ccs or PATH); skipped #{path}", session_id)
      return
    end

    out = begin
      File.open(log_path, "a")
    rescue SystemCallError
      File.open(File::NULL, "a")
    end
    begin
      pid = Process.spawn(
        ccs, "ingest", "--file", path, "--with-subagents", "--quiet",
        pgroup: true, in: :close, out: out, err: out,
      )
      Process.detach(pid)
    ensure
      out.close
    end
  rescue JSON::ParserError
    nil
  rescue StandardError, ScriptError => e
    log("#{e.class}: #{e.message}", session_id)
  end
end

begin
  SessionIngestHook.run($stdin.read.to_s)
rescue Exception # rubocop:disable Lint/RescueException -- the hook must never fail
  nil
end
exit 0
