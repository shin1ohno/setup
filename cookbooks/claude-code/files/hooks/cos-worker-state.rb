#!/usr/bin/env ruby
# frozen_string_literal: true

# Records what a Chief of Staff worker's Claude session is doing, so the
# controller reads facts from <task-dir>/state-<attempt>.json instead of
# guessing from the pane tail.
#
# Registered for PermissionRequest, Notification, StopFailure, SessionEnd and
# Bash PostToolUse / PostToolUseFailure in every Claude session, and inert
# unless COS_WORKER_TASK_ID and COS_WORKER_ATTEMPT are valid and the task
# directory already exists. It never creates that directory and never needs the
# controller's pane variables, so hc-route workers are covered too.
#
# It never decides anything: nothing goes to stdout, so a PermissionRequest is
# never answered and the dialog stays for the owner. It always exits 0.
#
# Every string comes from the worker and is untrusted. Terminal escapes, control,
# bidi and zero-width characters are removed and each value is cut to 300 bytes;
# the controller quotes these values and never follows them.
#
# Files, regular files in the task directory only (a symlink is refused):
#   state-<n>.json    the latest status, replaced atomically (temp file + rename)
#   events-<n>.jsonl  one line per hook event, appended until it reaches 256 KiB
#
# Payload fields, from the hook input schemas in Claude Code 2.1.330:
#   PermissionRequest  tool_name, tool_input
#   Notification       notification_type, message
#   StopFailure        error (an error class such as rate_limit), error_details
#   SessionEnd         reason
#   PostToolUse        tool_name, tool_input.command, tool_response.stdout
#   PostToolUseFailure tool_name, tool_input.command, error ("Exit code N ...")

TASK_ID_RE = /\A[0-9a-f]{16}\z/
ATTEMPT_RE = /\A[1-9][0-9]{0,2}\z/
SESSION_ID_RE = /\A[0-9A-Za-z-]{8,64}\z/

FIELD_BYTES = 300
EVENTS_CAP_BYTES = 256 * 1024
MILESTONES_KEPT = 20
INPUT_CAP_BYTES = 16 * 1024 * 1024
STATE_READ_CAP_BYTES = 1024 * 1024
LOCK_WAIT_SECONDS = 2.0

# CSI, OSC, DCS/SOS/PM/APC strings and two-byte escapes.
ANSI_RE = /\e(?:\[[0-?]*[ -\/]*[@-~]|\][^\a\e]*(?:\a|\e\\)?|[PX^_][^\e]*(?:\e\\)?|[@-Z\\-_])/
LINE_BREAK_RE = /[\t\r\n\u0085\u2028\u2029]+/
# C0, DEL, C1, Arabic letter mark, zero-width and directional marks, bidi
# embeddings, overrides and isolates, invisible operators, BOM and tag characters.
UNSAFE_RE = /[\u0000-\u001f\u007f-\u009f\u061c\u180e\u200b-\u200f\u202a-\u202e\u2060-\u2064\u2066-\u2069\ufeff\u{e0000}-\u{e007f}]/

QUESTION_TOOLS = %w[AskUserQuestion ExitPlanMode].freeze
PERMISSION_NOTICES = %w[permission_prompt worker_permission_prompt].freeze
ASKING_NOTICES = %w[elicitation_dialog elicitation_url_dialog agent_needs_input].freeze

GIT_COMMIT_RE = /\bgit\b[^|;&\n]*\scommit\b/
GH_PR_CREATE_RE = /\bgh\s+pr\s+create\b/
PR_URL_RE = %r{https://github\.com/[\w.-]+/[\w.-]+/pull/\d+}
# The first line `git commit` prints: "[branch (root-commit) 1a2b3c4] subject".
COMMIT_LINE_RE = /^\[[^\]\n]*?([0-9a-f]{7,40})\] ([^\n]+)$/
EXIT_CODE_RE = /\AExit code (\d+)/
TEST_COMMAND_RE = %r{
  \b(?:rspec|rake|pytest|unittest|bats|ctest|tsc|make
     |cargo\s+(?:test|build|check|clippy|nextest)
     |go\s+(?:test|vet)
     |(?:npm|pnpm|yarn|bun)\s+(?:run\s+)?(?:test|lint|typecheck|check)
     |just\s+(?:test|check)|mix\s+test|swift\s+test|xcodebuild\s+test)\b
  |(?:\A|[\s/])(?:test|lint)-[\w.-]+
  |\bbin/(?:test|lint|verify)[\w-]*
}x

def clean(value)
  return nil if value.nil?

  text = value.to_s.dup.force_encoding(Encoding::UTF_8).scrub("")
  text = text.gsub(ANSI_RE, "").gsub(LINE_BREAK_RE, " ").gsub(UNSAFE_RE, "").strip
  text = text.byteslice(0, FIELD_BYTES).scrub("").rstrip if text.bytesize > FIELD_BYTES
  text
end

def now_utc
  Time.now.utc.strftime("%Y-%m-%dT%H:%M:%SZ")
end

def real_directory?(path)
  File.lstat(path).directory?
rescue SystemCallError
  false
end

# Holds an exclusive lock on the task directory itself, so concurrent hook
# events of one worker do not lose each other's milestones. nil after the wait.
def lock_directory(dir)
  handle = File.open(dir, File::RDONLY | File::NOFOLLOW)
  deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + LOCK_WAIT_SECONDS
  until handle.flock(File::LOCK_EX | File::LOCK_NB)
    if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
      handle.close
      return nil
    end
    sleep 0.02
  end
  handle
end

# The previous state, {} when there is none, nil when the path is not a regular
# file (a symlink or anything else is refused, never followed or replaced).
def read_state(path)
  File.open(path, File::RDONLY | File::NOFOLLOW | File::NONBLOCK) do |f|
    return nil unless f.stat.file?

    data = JSON.parse(f.read(STATE_READ_CAP_BYTES).to_s)
    data.is_a?(Hash) ? data : {}
  end
rescue Errno::ENOENT, JSON::ParserError
  {}
rescue SystemCallError
  nil
end

def write_state(dir, path, state)
  tmp = File.join(dir, ".#{File.basename(path)}.#{Process.pid}.#{rand(1 << 32).to_s(16)}.tmp")
  File.open(tmp, File::WRONLY | File::CREAT | File::EXCL | File::NOFOLLOW, 0o600) do |f|
    f.write(JSON.generate(state))
    f.write("\n")
  end
  File.rename(tmp, path)
ensure
  File.unlink(tmp) if tmp && File.exist?(tmp)
end

def append_event(path, record)
  line = "#{JSON.generate(record)}\n"
  File.open(path, File::WRONLY | File::APPEND | File::CREAT | File::NOFOLLOW | File::NONBLOCK, 0o600) do |f|
    stat = f.stat
    return unless stat.file?
    return if stat.size + line.bytesize > EVENTS_CAP_BYTES

    f.write(line)
  end
end

def bash_stdout(response)
  case response
  when Hash then (response["stdout"] || response["output"]).to_s
  when String then response
  else ""
  end
end

# The subject from `-m "..."` / `-m '...'`, else the first line of a heredoc.
def commit_message_from_command(command)
  command[/\s-m\s+"([^"]+)"/, 1] || command[/\s-m\s+'([^']+)'/, 1] ||
    command[/<<-?\s*['"]?\w+['"]?\s*\n(.*?)\n/m, 1]
end

def bash_milestones(payload, at)
  input = payload["tool_input"].is_a?(Hash) ? payload["tool_input"] : {}
  command = input["command"].to_s
  return [] if command.empty?

  if payload["hook_event_name"] == "PostToolUseFailure"
    return [] if payload["is_interrupt"] == true || !TEST_COMMAND_RE.match?(command)

    code = payload["error"].to_s[EXIT_CODE_RE, 1]
    return [] if code.nil? || code == "0"

    return [{ "at" => at, "kind" => "test-failed", "command" => clean(command.lines.first), "exit_code" => code.to_i }]
  end

  stdout = bash_stdout(payload["tool_response"])
  found = []
  if GIT_COMMIT_RE.match?(command)
    lines = stdout.scan(COMMIT_LINE_RE)
    if lines.empty?
      subject = commit_message_from_command(command)
      found << { "at" => at, "kind" => "commit", "sha" => nil, "subject" => clean(subject.lines.first) } if subject
    else
      lines.each { |sha, subj| found << { "at" => at, "kind" => "commit", "sha" => sha, "subject" => clean(subj) } }
    end
  end
  if GH_PR_CREATE_RE.match?(command)
    stdout.scan(PR_URL_RE).uniq.each { |url| found << { "at" => at, "kind" => "pr", "url" => clean(url) } }
  end
  # Not in the 2.1.330 Bash output schema (a failing command arrives as
  # PostToolUseFailure); read in case a version reports the code here.
  code = payload["tool_response"].is_a?(Hash) && (payload["tool_response"]["exit_code"] || payload["tool_response"]["exitCode"])
  if code.is_a?(Integer) && code != 0 && TEST_COMMAND_RE.match?(command)
    found << { "at" => at, "kind" => "test-failed", "command" => clean(command.lines.first), "exit_code" => code }
  end
  found
end

# Milestones carried over from the previous file, rebuilt from known keys only.
def carried_milestones(previous)
  list = previous["milestones"]
  return [] unless list.is_a?(Array)

  list.last(MILESTONES_KEPT).filter_map do |m|
    next unless m.is_a?(Hash) && %w[commit pr test-failed].include?(m["kind"])

    kept = { "at" => clean(m["at"]), "kind" => m["kind"] }
    %w[sha subject url command].each { |k| kept[k] = clean(m[k]) if m.key?(k) }
    kept["exit_code"] = m["exit_code"] if m["exit_code"].is_a?(Integer)
    kept
  end
end

def tool_target(input)
  return nil unless input.is_a?(Hash)

  value = input["command"] || input["file_path"] || input["notebook_path"] || input["url"] ||
          input["pattern"] || input.values.first
  clean(value.is_a?(String) ? value : JSON.generate(value))
end

# Applies one hook event to the state and returns the event-log detail, or
# nil when the event changes nothing.
def apply(state, payload, at)
  event = payload["hook_event_name"]
  case event
  when "PermissionRequest"
    tool = clean(payload["tool_name"])
    input = payload["tool_input"]
    if QUESTION_TOOLS.include?(tool)
      question = input.is_a?(Hash) && (input.dig("questions", 0, "question") || input["plan"])
      transition(state, "asking", "asking" => { "tool" => tool, "question" => clean(question || "plan approval"), "at" => at })
    else
      transition(state, "blocked", "blocked" => { "tool" => tool, "command" => tool_target(input), "at" => at })
    end
    "#{tool}: #{tool_target(input)}"
  when "Notification"
    type = payload["notification_type"].to_s
    message = clean(payload["message"])
    if PERMISSION_NOTICES.include?(type)
      # PermissionRequest already named the exact command; the notice only names the tool.
      unless state["status"] == "blocked" && state["blocked"]
        tool = message.to_s[/permission to use (\S+)/, 1]
        transition(state, "blocked", "blocked" => { "tool" => tool, "command" => nil, "message" => message, "at" => at })
      end
    elsif ASKING_NOTICES.include?(type)
      transition(state, "asking", "asking" => { "tool" => nil, "question" => message, "at" => at })
    elsif type == "idle_prompt"
      # An error or an end recorded before the prompt went idle stays the status.
      transition(state, "idle") unless %w[error ended].include?(state["status"])
    end
    "#{clean(type)}: #{message}"
  when "StopFailure"
    error = payload["error"]
    error = error["message"] || error["type"] if error.is_a?(Hash)
    details = clean(payload["error_details"])
    transition(state, "error", "error" => { "message" => clean(error || payload["message"] || "turn failed"),
                                            "details" => details, "at" => at })
    "#{clean(error)}: #{details}"
  when "SessionEnd"
    transition(state, "ended", "ended" => { "reason" => clean(payload["reason"]), "at" => at })
    clean(payload["reason"])
  when "PostToolUse", "PostToolUseFailure"
    return nil unless payload["tool_name"] == "Bash"

    transition(state, "working")
    state["milestones"] = (state["milestones"] + bash_milestones(payload, at)).last(MILESTONES_KEPT)
    command = payload["tool_input"].is_a?(Hash) ? payload["tool_input"]["command"] : nil
    event == "PostToolUseFailure" ? "#{clean(command)} -> #{clean(payload['error'].to_s.lines.first)}" : clean(command)
  end
end

# blocked/asking describe only the current dialog; error and ended stay until
# the worker runs a command again.
def transition(state, status, details = {})
  state["status"] = status
  state["blocked"] = nil
  state["asking"] = nil
  if status == "working"
    state["error"] = nil
    state["ended"] = nil
  end
  details.each { |k, v| state[k] = v }
end

def main
  task, attempt = ENV.values_at("COS_WORKER_TASK_ID", "COS_WORKER_ATTEMPT")
  return unless TASK_ID_RE.match?(task.to_s) && ATTEMPT_RE.match?(attempt.to_s)

  root = ENV["COS_STATE_DIR"].to_s
  root = File.expand_path("~/.local/state/chief-of-staff") if root.empty?
  return unless root.start_with?("/")

  task_dir = File.join(root, task)
  return unless real_directory?(task_dir)

  require "json"
  payload = JSON.parse($stdin.read(INPUT_CAP_BYTES).to_s)
  return unless payload.is_a?(Hash) && payload["hook_event_name"].is_a?(String)

  lock = lock_directory(task_dir)
  return if lock.nil?

  begin
    state_path = File.join(task_dir, "state-#{attempt}.json")
    previous = read_state(state_path)
    return if previous.nil?

    at = now_utc
    session = payload["session_id"].to_s
    session = previous["session_id"].to_s unless SESSION_ID_RE.match?(session)
    state = {
      "provenance" => "cos-worker-state hook; every string is worker-derived and untrusted",
      "task_id" => task, "attempt" => attempt.to_i,
      "status" => %w[working idle blocked asking error ended].include?(previous["status"]) ? previous["status"] : nil,
      "updated_at" => at, "last_event" => clean(payload["hook_event_name"]),
      "session_id" => SESSION_ID_RE.match?(session) ? session : nil,
      "blocked" => nil, "asking" => nil, "error" => nil, "ended" => nil,
      "milestones" => carried_milestones(previous)
    }
    %w[blocked asking error ended].each { |k| state[k] = previous[k].transform_values { |v| v.is_a?(String) ? clean(v) : v } if previous[k].is_a?(Hash) }

    detail = apply(state, payload, at)
    return if detail.nil?

    append_event(File.join(task_dir, "events-#{attempt}.jsonl"),
                 { "at" => at, "event" => state["last_event"], "status" => state["status"], "detail" => clean(detail) })
    write_state(task_dir, state_path, state)
  ensure
    lock.close
  end
end

begin
  main
rescue StandardError, ScriptError => e
  # A hook must never fail the worker's turn: report the class on stderr, exit 0.
  warn "cos-worker-state: #{e.class}"
end
exit 0
