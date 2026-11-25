#!/usr/bin/env ruby
# frozen_string_literal: true

# Agent Board: a read-only local web view of the Chief of Staff task ledger.
#
#   ruby board.rb [--port N] [--bind ADDR] [--no-gh] [--state-dir DIR]
#   ruby board.rb --snapshot OUT.html   one self-contained page, no server
#   ruby board.rb --dump-json           the data the page polls, on stdout
#
# The server uses WEBrick (not a default gem since Ruby 3.0; the claude-code
# cookbook installs it) and answers GET / (the page) and GET /api/board (JSON
# the page polls every POLL_SECONDS). It binds only to a loopback address,
# refuses a request whose Host header is not a loopback name (DNS rebinding)
# and answers every other method with 405. /api/board also needs the per-run
# token: board.rb prints the URL as http://127.0.0.1:PORT/#t=<token>, the page
# sends the fragment back as an X-Board-Token header, and any other request
# gets 403. The fragment never reaches the server, so no request line or log
# holds the token, and another local OS account that can reach the loopback
# port still cannot read the 0700 ledger through the board.
#
# It never writes, renames or deletes anything under the state directory:
# every file is opened read-only, without following symlinks, non-blocking (a
# FIFO cannot hang it) and with a size cap. A task whose files are malformed,
# truncated or mid-rewrite is listed under "unreadable" and the rest are still
# served. Pull request state comes from `gh pr view` on a background thread,
# cached PR_TTL seconds per URL; without gh (or with --no-gh) a PR is a link.
#
# Every string in the ledger, the inbox, the worker state files and the
# checklist is worker- or controller-derived data. The page builds its DOM with
# textContent only; the snapshot embeds the JSON with <, > and & escaped.

require "io/wait"
require "ipaddr"
require "json"
require "optparse"
require "securerandom"
require "time"
require "tmpdir"

module Board
  DEFAULT_PORT = 47_100
  POLL_SECONDS = 5
  PR_TTL = 90
  GH_TIMEOUT = 10
  IDLE_WINDOW = 24 * 3600
  WORKING_WINDOW = 15 * 60
  STALL_SECONDS = 10 * 60
  TRACE_BINS = 12
  TRACE_BIN_SECONDS = 5 * 60
  TIMELINE_LIMIT = 200
  INBOX_LIMIT = 400

  TASK_ID = /\A[0-9a-f]{16}\z/
  NONCE = /\A[0-9a-f]{16}\z/
  INBOX_NAME = /\A([1-9][0-9]{0,2})-([0-9]+)-[0-9a-f]{8,}\.json\z/
  INBOX_KEYS = %w[at attempt kind nonce on step task_id text].freeze
  INBOX_KINDS = %w[done failed blocked question wait step note].freeze
  CHECKLIST_KEYS = %w[at attempt changes items nonce started_at task_id].freeze
  CHECKLIST_STATES = %w[todo doing done failed].freeze
  STEP = %r{\A[0-9]{1,3}/[0-9]{1,3}\z}
  PR_URL = %r{\Ahttps://github\.com/([A-Za-z0-9](?:[A-Za-z0-9-]{0,38}))/([A-Za-z0-9._-]{1,100})/pull/([1-9][0-9]{0,9})\z}

  NEEDS = %w[needs-user].freeze
  WORKING = %w[queued starting running reviewing retry].freeze
  IDLE = %w[accepted cancelled].freeze

  LIMITS = {
    task: 4 * 1024 * 1024, state: 512 * 1024, inbox: 8192, checklist: 64 * 1024,
    digest: 16 * 1024, prompt: 16 * 1024, events: 64 * 1024
  }.freeze

  # The same cleaning as inbox.py clean(): escapes, controls (line breaks fold to
  # a space), bidi and zero-width characters, backticks; NFC; a byte cut.
  ANSI = /\e\[[0-?]*[ -\/]*[@-~]|\e\][^\a\e]*(?:\a|\e\\)?|\e[@-_]/
  FOLD = /[\r\n\t\v\f\u2028\u2029\u0085]/
  CONTROLS = /[\u0000-\u001f\u007f-\u009f]/
  INVISIBLE = /[\u00ad\u061c\u180e\u200b-\u200f\u202a-\u202e\u2060-\u2069\ufeff]/

  class Unreadable < StandardError; end

  module_function

  def clean(value, limit = 300)
    return nil unless value.is_a?(String)

    text = value.dup.force_encoding("UTF-8").scrub("")
    text = text.gsub(ANSI, "").gsub(FOLD, " ").gsub(CONTROLS, "").gsub(INVISIBLE, "").tr("`", "'")
    text = text.unicode_normalize(:nfc).strip
    text = text.byteslice(0, limit).scrub("") if text.bytesize > limit
    text.empty? ? nil : text
  end

  def time(value)
    return nil unless value.is_a?(String) && value.bytesize <= 64

    Time.iso8601(value).utc
  rescue ArgumentError
    nil
  end

  def iso(value)
    value&.utc&.iso8601
  end

  # --- loopback gates --------------------------------------------------------

  def loopback_address?(text)
    return false unless text.is_a?(String)

    if text.match?(/\A127\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\z/)
      text.split(".").all? { |part| part.to_i <= 255 }
    elsif text.match?(/\A[0-9a-fA-F:]+\z/) && text.include?(":")
      IPAddr.new(text) == IPAddr.new("::1")
    else
      false
    end
  rescue IPAddr::Error
    false
  end

  # Host header: localhost, 127.0.0.0/8 or [::1], with an optional port.
  def loopback_host?(value)
    return false unless value.is_a?(String)

    host = value.strip.downcase
    name = if host.start_with?("[")
             host[/\A\[([0-9a-f:]+)\](?::[0-9]{1,5})?\z/, 1]
           else
             host[/\A([a-z0-9.]+)(?::[0-9]{1,5})?\z/, 1]
           end
    return false unless name

    name == "localhost" || loopback_address?(name)
  end

  # --- safe reads ---------------------------------------------------------------

  # A regular file's content, nil when absent. Never follows a symlink, never
  # blocks on a FIFO, never reads past `limit`.
  def read_file(path, limit)
    info = File.lstat(path)
    raise Unreadable, "#{File.basename(path)} is not a regular file" unless info.file?

    File.open(path, File::RDONLY | File::NOFOLLOW | File::NONBLOCK) do |file|
      raise Unreadable, "#{File.basename(path)} is not a regular file" unless file.stat.file?

      data = file.read(limit + 1) || +""
      raise Unreadable, "#{File.basename(path)} exceeds #{limit} bytes" if data.bytesize > limit

      data.force_encoding("UTF-8")
    end
  rescue Errno::ENOENT, Errno::ENOTDIR
    nil
  rescue Errno::ELOOP, Errno::EACCES, Errno::EISDIR, Errno::ENXIO, Errno::EAGAIN => e
    raise Unreadable, "#{File.basename(path)}: #{e.class.name.split('::').last}"
  end

  def read_json(path, limit)
    data = read_file(path, limit)
    return nil if data.nil?
    raise Unreadable, "#{File.basename(path)} is not UTF-8" unless data.valid_encoding?

    JSON.parse(data, max_nesting: 20)
  rescue JSON::ParserError
    raise Unreadable, "#{File.basename(path)} is not valid JSON (truncated or mid-rewrite)"
  end

  # The last `limit` bytes of a regular file (an append-only log), nil when
  # absent; the same no-symlink, no-FIFO discipline as read_file.
  def read_tail(path, limit)
    info = File.lstat(path)
    raise Unreadable, "#{File.basename(path)} is not a regular file" unless info.file?

    File.open(path, File::RDONLY | File::NOFOLLOW | File::NONBLOCK) do |file|
      stat = file.stat
      raise Unreadable, "#{File.basename(path)} is not a regular file" unless stat.file?

      offset = [stat.size - limit, 0].max
      file.seek(offset)
      data = (file.read(limit) || +"").force_encoding("UTF-8").scrub("")
      offset.positive? ? data.sub(/\A[^\n]*\n?/, "") : data
    end
  rescue Errno::ENOENT, Errno::ENOTDIR
    nil
  rescue Errno::ELOOP, Errno::EACCES, Errno::EISDIR, Errno::ENXIO, Errno::EAGAIN => e
    raise Unreadable, "#{File.basename(path)}: #{e.class.name.split('::').last}"
  end

  # Times of the hook events in events-<n>.jsonl (newest 64 KiB). Only the
  # timestamps are used; the event text never reaches the page.
  def event_times(dir, number)
    data = begin
      read_tail(File.join(dir, "events-#{number}.jsonl"), LIMITS[:events])
    rescue Unreadable
      nil
    end
    return [] unless data

    data.each_line.filter_map do |line|
      body = JSON.parse(line, max_nesting: 5)
      body.is_a?(Hash) ? time(body["at"]) : nil
    rescue JSON::ParserError
      nil
    end
  end

  # Component files degrade to nil: one bad state file must not hide the task.
  def soft_json(path, limit)
    read_json(path, limit)
  rescue Unreadable
    nil
  end

  def entries(dir)
    Dir.children(dir)
  rescue SystemCallError
    []
  end

  def real_dir?(path)
    File.lstat(path).directory?
  rescue SystemCallError
    false
  end

  # --- one task -----------------------------------------------------------------

  def str(value, limit = 300)
    clean(value, limit)
  end

  def inbox_messages(dir, task)
    attempts = task["attempts"]
    found = []
    [File.join(dir, "inbox"), File.join(dir, "inbox", "read")].each do |box|
      next unless real_dir?(box)

      entries(box).filter_map { |name| (m = INBOX_NAME.match(name)) && [m[2].to_i, name, m[1].to_i] }
                  .max_by(INBOX_LIMIT) { |ns, _, _| ns }.each do |_, name, number|
        body = soft_json(File.join(box, name), LIMITS[:inbox])
        next unless body.is_a?(Hash) && body.keys.sort == INBOX_KEYS
        next unless body["task_id"] == task["id"] && body["attempt"] == number
        next unless number.is_a?(Integer) && number.between?(1, attempts.size)

        nonce = attempts[number - 1].is_a?(Hash) ? attempts[number - 1]["nonce"] : nil
        next unless nonce.is_a?(String) && NONCE.match?(nonce) && body["nonce"] == nonce
        next unless INBOX_KINDS.include?(body["kind"])
        next if !body["step"].nil? && !(body["step"].is_a?(String) && STEP.match?(body["step"]))

        text = str(body["text"], 1200)
        at = time(body["at"])
        next unless text && at

        found << { at: at, attempt: number, kind: body["kind"], text: text, on: str(body["on"], 80),
                   step: body["step"] }
      end
    end
    found.sort_by { |m| m[:at] }
  end

  def checklist_item(value, nested)
    return nil unless value.is_a?(Hash)

    text = str(value["text"], 200)
    state = value["state"]
    return nil unless text && CHECKLIST_STATES.include?(state)

    item = { text: text, state: state, children: [] }
    if !nested && value["children"].is_a?(Array)
      item[:children] = value["children"].first(15).filter_map { |child| checklist_item(child, true) }
    end
    item
  end

  # The current attempt's checklist when its task ID, attempt and nonce match
  # the ledger; otherwise nil plus the reason.
  def checklist(dir, task, number)
    path = File.join(dir, "checklist-#{number}.json")
    body = begin
      read_json(path, LIMITS[:checklist])
    rescue Unreadable => e
      return [nil, e.message]
    end
    return [nil, nil] if body.nil?
    return [nil, "checklist has invalid fields"] unless body.is_a?(Hash) && body.keys.sort == CHECKLIST_KEYS
    return [nil, "checklist belongs to another task"] unless body["task_id"] == task["id"]
    return [nil, "checklist is not for the current attempt"] unless body["attempt"] == number

    nonce = task["attempts"][number - 1].is_a?(Hash) ? task["attempts"][number - 1]["nonce"] : nil
    return [nil, "checklist nonce does not match the current attempt"] unless
      nonce.is_a?(String) && NONCE.match?(nonce) && body["nonce"] == nonce
    return [nil, "checklist items are not a list"] unless body["items"].is_a?(Array)

    items = body["items"].first(30).filter_map { |value| checklist_item(value, false) }
    changes = (body["changes"].is_a?(Array) ? body["changes"] : []).last(200).filter_map do |change|
      next unless change.is_a?(Hash) && (at = time(change["at"]))

      if change["plan"].is_a?(Integer)
        { at: at, plan: change["plan"] }
      elsif CHECKLIST_STATES.include?(change["to"]) && (text = str(change["text"], 200))
        { at: at, text: text, parent: str(change["parent"], 200), to: change["to"] }
      end
    end
    [{ items: items, changes: changes, at: time(body["at"]), started_at: time(body["started_at"]) }, nil]
  end

  def leaves(items)
    items.flat_map { |item| item[:children].empty? ? [item] : item[:children] }
  end

  def progress(items)
    all = leaves(items)
    counts = CHECKLIST_STATES.to_h { |s| [s.to_sym, all.count { |i| i[:state] == s }] }
    counts.merge(total: all.size)
  end

  def acceptance_items(task)
    criteria = task["acceptance"].is_a?(Array) ? task["acceptance"] : []
    marks = {}
    envelope = task["envelope"]
    if envelope.is_a?(Hash) && envelope["criteria"].is_a?(Array)
      envelope["criteria"].each do |c|
        marks[c["criterion"]] = c["status"] if c.is_a?(Hash) && c["criterion"].is_a?(String)
      end
    end
    criteria.first(40).filter_map do |criterion|
      text = str(criterion, 400)
      next unless text

      mark = marks[criterion]
      state = { "pass" => "done", "fail" => "failed", "unverified" => "doing" }.fetch(mark, "todo")
      { text: text, state: state, children: [], mark: (%w[pass fail unverified].include?(mark) ? mark : nil) }
    end
  end

  def pr_records(task)
    list = task["pr"].is_a?(Array) ? task["pr"] : []
    list.first(20).filter_map do |pr|
      next unless pr.is_a?(Hash) && pr["url"].is_a?(String) && (m = PR_URL.match(pr["url"]))

      { url: pr["url"], label: "#{m[2]}##{m[3]}", added_at: time(pr["added_at"]) }
    end.uniq { |pr| pr[:url] }
  end

  def state_color(state)
    case state
    when "accepted" then "green"
    when "needs-user" then "amber"
    when "cancelled" then "grey"
    when "retry" then "red"
    else "blue"
    end
  end

  KIND_COLOR = { "done" => "green", "failed" => "red", "blocked" => "red", "question" => "amber",
                 "wait" => "amber", "step" => "blue", "note" => "grey" }.freeze
  CHECK_COLOR = { "done" => "green", "doing" => "blue", "failed" => "red", "todo" => "grey" }.freeze

  def owner_named?(on, owner)
    return false unless on

    down = on.downcase
    down.match?(/\b(owner|user|you)\b/) || on.include?("オーナー") || on.include?("ユーザー") ||
      (owner && on.include?(owner))
  end

  def task_row(dir, task, now, prs)
    id = task["id"]
    attempts = task["attempts"]
    number = attempts.size
    attempt = number.positive? && attempts.last.is_a?(Hash) ? attempts.last : {}
    state = task["state"].is_a?(String) ? task["state"] : "unknown"
    owner = str(task["owner"], 200)
    topic = str(task["topic"], 400) || "(no topic)"

    state_file = number.positive? ? soft_json(File.join(dir, "state-#{number}.json"), LIMITS[:state]) : nil
    state_file = nil unless state_file.is_a?(Hash) && state_file["attempt"] == number &&
                            (state_file["task_id"].nil? || state_file["task_id"] == id)
    status = state_file && %w[working idle blocked asking error ended].include?(state_file["status"]) ? state_file["status"] : nil
    status_at = state_file && time(state_file["updated_at"])
    digest = number.positive? ? soft_json(File.join(dir, "digest-#{number}.json"), LIMITS[:digest]) : nil
    digest = nil unless digest.is_a?(Hash) && digest["attempt"] == number
    events = number.positive? ? event_times(dir, number) : []
    milestones = state_file && state_file["milestones"].is_a?(Array) ? state_file["milestones"] : []

    messages = inbox_messages(dir, task)
    current = messages.select { |m| m[:attempt] == number }
    list, checklist_error = number.positive? ? checklist(dir, task, number) : [nil, nil]
    history = (task["history"].is_a?(Array) ? task["history"] : []).select { |h| h.is_a?(Hash) }

    # --- section and what the owner must decide
    need = nil
    if NEEDS.include?(state)
      entry = history.reverse.find { |h| h["state"] == "needs-user" }
      need = str(entry && entry["note"], 400) || "the controller is waiting for your answer"
    elsif !IDLE.include?(state)
      if status == "blocked" && state_file["blocked"].is_a?(Hash)
        b = state_file["blocked"]
        need = "approve or deny a #{str(b['tool'], 80) || 'permission'} dialog" +
               ((c = str(b["command"], 200) || str(b["message"], 200)) ? ": #{c}" : "")
      elsif status == "asking" && state_file["asking"].is_a?(Hash)
        need = "answer: #{str(state_file['asking']['question'], 300) || 'a question in the worker pane'}"
      elsif (latest = current.last) && %w[question wait].include?(latest[:kind]) && owner_named?(latest[:on], owner)
        need = latest[:text]
      end
    end
    if need && digest && (decide = str(digest["decide"], 200)) && !IDLE.include?(state)
      need = "#{need} (#{decide})" unless need.include?(decide)
    end
    section = if need then "needs_you"
              elsif IDLE.include?(state) then "idle"
              else "working"
              end

    # --- times
    stamps = [time(task["updated_at"]), status_at, current.last&.dig(:at), list&.dig(:at)].compact
    updated = stamps.max
    working = section == "working" && status == "working" && status_at && (now - status_at) < WORKING_WINDOW
    # Last recorded activity, the stalled rule's clock: the state file, the
    # newest hook event, the newest inbox message and the ledger update.
    activity_at = [status_at, events.max, current.last&.dig(:at), time(task["updated_at"])].compact.max
    last_message = current.last
    # Waiting: an explicit `wait --on <who>`, or the worker has handed back to
    # the controller (a finishing report, a last step i/n with i == n, its
    # envelope file, or the ledger in review). Waiting is never stalled.
    finished_step = last_message && last_message[:kind] == "step" &&
                    (m = last_message[:step].to_s.match(%r{\A([0-9]+)/([0-9]+)\z})) && m[1] == m[2]
    envelope_file = number.positive? && begin
      File.lstat(File.join(dir, "envelope-#{number}.json")).file?
    rescue SystemCallError
      false
    end
    waiting = nil
    if section == "working"
      if last_message && last_message[:kind] == "wait"
        waiting = { on: last_message[:on] || "someone", text: last_message[:text] }
      elsif last_message && %w[done failed blocked].include?(last_message[:kind]) || finished_step
        waiting = { on: "controller", text: last_message[:text] }
      elsif envelope_file
        waiting = { on: "controller", text: "The worker wrote its envelope." }
      elsif state == "reviewing"
        waiting = { on: "controller", text: "The controller is reviewing the result." }
      end
    end
    stalled = section == "working" && !waiting && activity_at && (now - activity_at) >= STALL_SECONDS ? true : false
    phase = if section == "needs_you" then "needs"
            elsif state == "accepted" then "done"
            elsif state == "cancelled" then "cancelled"
            elsif waiting then "waiting"
            elsif status == "error" then "error"
            elsif state == "retry" then "retry"
            elsif stalled then "stalled"
            elsif state == "queued" then "queued"
            else "working"
            end
    started = time(attempt["created_at"]) || time(task["created_at"])

    # --- activity trace: the same sources as activity_at, counted per
    # TRACE_BIN_SECONDS over the last hour, oldest bin first
    trace = Array.new(TRACE_BINS, 0)
    marks = events + current.map { |m| m[:at] } + [status_at, time(task["updated_at"])].compact
    marks.each do |t|
      age = now - t
      next if age < -60 # a clock far ahead is not activity

      bin = (age.clamp(0, Float::INFINITY) / TRACE_BIN_SECONDS).floor
      trace[TRACE_BINS - 1 - bin] += 1 if bin < TRACE_BINS
    end

    # --- tasks block
    tasks = if list
              { source: "checklist", items: list[:items], started_at: iso(list[:started_at]) }
            else
              { source: "acceptance", items: acceptance_items(task),
                started_at: iso(time(attempt["created_at"]) || time(task["created_at"])),
                note: checklist_error }
            end
    ended = IDLE.include?(state) ? updated : nil
    tasks[:ended_at] = iso(ended)
    tasks[:progress] = progress(tasks[:items])

    # --- pull requests
    records = pr_records(task)
    milestones.each do |m|
      next unless m.is_a?(Hash) && m["kind"] == "pr" && m["url"].is_a?(String) && (match = PR_URL.match(m["url"]))
      next if records.any? { |r| r[:url] == m["url"] }

      records << { url: m["url"], label: "#{match[2]}##{match[3]}", added_at: nil }
    end
    pr_list = records.map do |r|
      info = prs.lookup(r[:url])
      { url: r[:url], label: r[:label], state: info && info[:text], merged: info && info[:merged],
        status: info && info[:status], ci: info && info[:ci] }
    end

    # --- timeline
    timeline = []
    history.each do |h|
      next unless (at = time(h["at"]))

      hs = str(h["state"], 40) || "?"
      note = str(h["note"], 400)
      timeline << { at: at, color: state_color(hs), text: "Ledger → #{hs}#{note ? ": #{note}" : ''}" }
    end
    attempts.each_with_index do |a, index|
      next unless a.is_a?(Hash) && (at = time(a["created_at"]))

      who = str(a["agent"], 120) || str(a["kind"], 20) || "worker"
      timeline << { at: at, color: "grey", text: "Attempt #{index + 1}: #{who} (#{str(a['kind'], 20) || '?'}, #{str(a['route'], 20) || '?'})" }
      prompt = begin
        read_file(File.join(dir, "launch-prompt-#{index + 1}.txt"), LIMITS[:prompt])
      rescue Unreadable
        nil
      end
      text = str(prompt, 400)
      timeline << { at: at, color: "grey", text: "From chief-of-staff #{text}" } if text
    end
    messages.each do |m|
      label = case m[:kind]
              when "done", "failed", "blocked" then "Report (#{m[:kind]})"
              when "question" then "Question"
              when "wait" then "Waiting on #{m[:on] || '?'}"
              when "step" then "Step #{m[:step]}"
              else "Note"
              end
      prefix = m[:attempt] == number ? "" : "[attempt #{m[:attempt]}] "
      timeline << { at: m[:at], color: KIND_COLOR[m[:kind]], text: "#{prefix}#{label} #{m[:text]}" }
    end
    list&.dig(:changes)&.each do |c|
      if c[:plan]
        timeline << { at: c[:at], color: "blue", text: "Plan: #{c[:plan]} tasks" }
      else
        timeline << { at: c[:at], color: CHECK_COLOR[c[:to]], text: "#{c[:text]} → #{c[:to]}" }
      end
    end
    milestones.last(40).each do |m|
      next unless m.is_a?(Hash) && (at = time(m["at"]))

      case m["kind"]
      when "commit"
        sha = m["sha"].is_a?(String) && m["sha"].match?(/\A[0-9a-f]{4,40}\z/) ? "#{m['sha'][0, 7]} " : ""
        timeline << { at: at, color: "grey", text: "Commit #{sha}#{str(m['subject'], 200) || ''}".strip }
      when "test-failed"
        code = m["exit_code"].is_a?(Integer) ? m["exit_code"] : "?"
        timeline << { at: at, color: "red", text: "Test failed (exit #{code}): #{str(m['command'], 200) || ''}" }
      when "pr"
        label = (match = PR_URL.match(m["url"].to_s)) ? "#{match[2]}##{match[3]}" : str(m["url"], 200)
        timeline << { at: at, color: "purple", text: "PR #{label} created by the worker" }
      end
    end
    records.each do |r|
      next unless r[:added_at]

      info = prs.lookup(r[:url])
      timeline << { at: r[:added_at], color: "purple", text: "PR #{r[:label]} opened#{info ? " (#{info[:text]})" : ''}" }
    end
    if (report = task["last_report"]).is_a?(Hash) && (at = time(report["at"])) && (note = str(report["note"], 600))
      timeline << { at: at, color: "grey", text: "Controller report: #{note}" }
    end
    timeline = timeline.sort_by { |t| -t[:at].to_f }.first(TIMELINE_LIMIT).map { |t| t.merge(at: iso(t[:at])) }

    # --- last report: the worker's latest inbox message, else the controller's
    latest = current.reverse.find { |m| %w[done failed blocked question wait step note].include?(m[:kind]) }
    last_report = if latest
                    { at: iso(latest[:at]), text: latest[:text], kind: latest[:kind] }
                  elsif (report = task["last_report"]).is_a?(Hash) && str(report["note"], 600)
                    { at: iso(time(report["at"])), text: str(report["note"], 600), kind: "controller" }
                  elsif digest && (did = str(digest["did"], 300))
                    { at: iso(time(digest["at"])), text: did, kind: "digest" }
                  end

    # --- the row's progress: the checklist, else the latest step i/n of this
    # attempt, else nothing (acceptance criteria are not progress)
    step = current.reverse.find { |m| m[:kind] == "step" }
    row_progress = if list && !list[:items].empty?
                     tasks[:progress].merge(source: "checklist")
                   elsif step && (m = step[:step].to_s.match(%r{\A([0-9]+)/([0-9]+)\z})) && m[2].to_i.positive?
                     done = [m[1].to_i, m[2].to_i].min
                     { source: "step", done: done, total: m[2].to_i, doing: 0, failed: 0, todo: m[2].to_i - done }
                   else
                     { source: "none", done: 0, total: 0, doing: 0, failed: 0, todo: 0 }
                   end

    # --- what is happening now, in priority order
    doing = leaves(list ? list[:items] : []).find { |i| i[:state] == "doing" } ||
            (list ? list[:items] : []).find { |i| i[:state] == "doing" }
    now_line = if need then { kind: "need", text: need }
               elsif waiting then { kind: "waiting", text: waiting[:text], on: waiting[:on] }
               elsif section == "working" && doing then { kind: "doing", text: doing[:text] }
               elsif section == "working" && step then { kind: "step", text: step[:text], step: step[:step] }
               elsif last_report then { kind: "report", text: last_report[:text] }
               end

    # --- facts (pull requests are in the row and in the detail's PR list)
    route = str(attempt["route"], 20)
    terminal = str(attempt["terminal_id"], 80) || str(attempt["pane"], 80)
    facts = []
    facts << { label: "Lane", value: [route || "?", terminal ? "terminal #{terminal}" : nil].compact.join(", ") }
    facts << if state_file
               { label: "Status", value: "#{status || 'unknown'}, file updated", at: iso(status_at) }
             elsif str(attempt["kind"], 20) == "codex"
               { label: "Status", value: "no state file (Codex worker)" }
             else
               { label: "Status", value: "no state file" }
             end
    facts << { label: "Ledger", value: "#{state}, attempt #{number} of #{task['max_attempts'].is_a?(Integer) ? task['max_attempts'] : '?'}" }
    facts << { label: "Controller", value: owner || "(no controller key)" }
    facts << { label: "Task", value: id }
    facts << { label: "Checklist", value: checklist_error } if checklist_error

    {
      id: id, topic: topic, owner: owner, controller_tag: controller_tag(owner), state: state,
      section: section, need: need,
      color: if section == "needs_you" then "amber"
             elsif status == "error" || state == "retry" then "red"
             elsif section == "working" then (working ? "blue" : "teal")
             else state_color(state)
             end,
      agent: str(attempt["agent"], 120) || str(attempt["kind"], 20) || "(no worker yet)",
      kind: str(attempt["kind"], 20), attempt: number,
      repo: task["cwd"].is_a?(String) ? str(File.basename(task["cwd"].sub(%r{/+\z}, "")), 80) : nil,
      phase: phase, stalled: stalled, waiting_on: waiting && waiting[:on],
      progress: row_progress,
      now: now_line, started_at: iso(started), activity_at: iso(activity_at), trace: trace,
      updated_at: iso(updated), working: working ? true : false,
      recent: section != "idle" || (updated && (now - updated) < IDLE_WINDOW) ? true : false,
      prs: pr_list, tasks: tasks, last_report: last_report, timeline: timeline, facts: facts
    }
  end

  def board(root, prs, now: Time.now.utc)
    rows = []
    errors = []
    entries(root).sort.each do |name|
      next unless TASK_ID.match?(name)

      dir = File.join(root, name)
      begin
        raise Unreadable, "task directory is not a real directory" unless real_dir?(dir)

        task = read_json(File.join(dir, "task.json"), LIMITS[:task])
        next if task.nil? # a directory without a ledger record yet

        raise Unreadable, "task.json is not an object" unless task.is_a?(Hash)
        raise Unreadable, "task.json id does not match its directory" unless task["id"] == name

        task["attempts"] = [] unless task["attempts"].is_a?(Array)
        rows << task_row(dir, task, now, prs)
      rescue Unreadable => e
        errors << { task: name, reason: e.message }
      rescue StandardError => e
        errors << { task: name, reason: "#{e.class}: #{str(e.message, 200)}" }
      end
    end
    recency = ->(r) { time(r[:updated_at])&.to_f || 0 }
    start = ->(r) { time(r[:started_at])&.to_f || 0 }
    needs, others = rows.partition { |r| r[:section] == "needs_you" }
    # One group per controller (ledger owner key). The order is stable under
    # polling: groups with working rows first, then by key; inside a group,
    # working rows newest start first, then idle rows newest update first.
    groups = others.group_by { |r| r[:owner] }.map do |owner, list|
      live, idle = list.partition { |r| r[:section] != "idle" }
      mine = list + needs.select { |r| r[:owner] == owner }
      repos = mine.filter_map { |r| r[:repo] }.tally.sort_by { |name, n| [-n, name] }.map(&:first)
      # Disjoint: a stalled or waiting row is not also counted as working.
      counts = { working: live.count { |r| !%w[stalled waiting].include?(r[:phase]) },
                 stalled: live.count { |r| r[:phase] == "stalled" },
                 waiting: live.count { |r| r[:phase] == "waiting" },
                 needs: needs.count { |r| r[:owner] == owner }, idle: idle.size }
      { owner: owner, label: owner || "(no controller key)", tag: controller_tag(owner),
        repos: repos.first(8), counts: counts,
        rows: live.sort_by { |r| [-start.call(r), r[:id]] } + idle.sort_by { |r| [-recency.call(r), r[:id]] } }
    end
    groups = groups.sort_by { |g| [g[:rows].any? { |r| r[:section] != "idle" } ? 0 : 1, g[:owner] ? 0 : 1, g[:label]] }
    { generated_at: iso(now), poll_seconds: POLL_SECONDS, state_dir: File.basename(root),
      gh: prs.enabled?, needs_you: needs.sort_by { |r| -recency.call(r) }, groups: groups,
      errors: errors }
  end

  # The short controller name for a Needs you row: what follows the first "#"
  # of the owner key (hc:default#t10 -> t10, herdr:sock#w1:p1 -> w1:p1).
  def controller_tag(owner)
    return "no key" unless owner

    str(owner.include?("#") ? owner.split("#", 2)[1] : owner, 80) || owner
  end

  # --- pull request state through gh -----------------------------------------------

  class PrCache
    FIELDS = "isDraft,state,reviewDecision,statusCheckRollup,mergedAt"

    def initialize(enabled:, ttl: PR_TTL, timeout: GH_TIMEOUT, background: true)
      @enabled = enabled
      @ttl = ttl
      @timeout = timeout
      @background = background
      @cache = {}
      @lock = Mutex.new
      @queue = Queue.new
      @queued = {}
      @worker = nil
      @child = nil
    end

    # Kill a gh still running when the server stops.
    def stop
      pid = @lock.synchronize { @child }
      Process.kill("KILL", -pid) if pid
    rescue SystemCallError
      nil
    end

    def enabled?
      @enabled
    end

    # The cached state text, or nil (link only). Never waits for gh when
    # running in the background; schedules a refresh when stale.
    def lookup(url)
      return nil unless @enabled && PR_URL.match?(url)

      entry = @lock.synchronize { @cache[url] }
      fresh = entry && (monotonic - entry[:at]) < @ttl
      unless fresh
        if @background
          schedule(url)
        else
          entry = refresh(url)
        end
      end
      entry && entry[:data]
    end

    def schedule(url)
      @lock.synchronize do
        return if @queued[url]

        @queued[url] = true
        @worker ||= Thread.new { work }
      end
      @queue << url
    end

    def work
      loop do
        url = @queue.pop
        refresh(url)
        @lock.synchronize { @queued.delete(url) }
      end
    end

    def refresh(url)
      entry = { at: monotonic, data: summarize(view(url)) }
      @lock.synchronize { @cache[url] = entry }
      entry
    end

    def monotonic
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    # gh's JSON, or nil on any failure (missing gh, auth, timeout, bad output).
    def view(url)
      env = { "GH_PROMPT_DISABLED" => "1", "NO_COLOR" => "1", "GH_NO_UPDATE_NOTIFIER" => "1" }
      reader, writer = IO.pipe
      pid = Process.spawn(env, "gh", "pr", "view", url, "--json", FIELDS,
                          in: File::NULL, out: writer, err: File::NULL, pgroup: true, chdir: Dir.tmpdir)
      @lock.synchronize { @child = pid }
      writer.close
      output = +""
      deadline = monotonic + @timeout
      while (left = deadline - monotonic).positive?
        break unless reader.wait_readable(left)

        chunk = reader.read_nonblock(65_536, exception: false)
        break if chunk.nil?
        next if chunk == :wait_readable

        output << chunk
        break if output.bytesize > 1_048_576
      end
      timed_out = monotonic >= deadline
      begin
        Process.kill("KILL", -pid) if timed_out
      rescue SystemCallError
        nil
      end
      _, status = Process.wait2(pid)
      @lock.synchronize { @child = nil }
      return nil if timed_out || !status.success?

      JSON.parse(output)
    rescue SystemCallError, JSON::ParserError, IOError
      nil
    ensure
      reader&.close unless reader&.closed?
      writer&.close unless writer&.closed?
    end

    def summarize(data)
      return nil unless data.is_a?(Hash)

      parts = []
      ci = nil
      merged = data["state"] == "MERGED" || data["mergedAt"].is_a?(String)
      if merged
        parts << "merged"
      elsif data["state"] == "CLOSED"
        parts << "closed"
      else
        parts << (data["isDraft"] == true ? "draft" : "open")
        ci = ci_summary(data["statusCheckRollup"])
        parts << ci if ci
        review = { "REVIEW_REQUIRED" => "review requested", "APPROVED" => "approved",
                   "CHANGES_REQUESTED" => "changes requested" }[data["reviewDecision"]]
        parts << review if review
      end
      { text: parts.join(" · "), merged: merged, status: parts.first,
        ci: ci && { "CI failing" => "failing", "CI pending" => "pending", "CI passing" => "passing" }[ci] }
    end

    def ci_summary(rollup)
      return nil unless rollup.is_a?(Array) && !rollup.empty?

      checks = rollup.select { |c| c.is_a?(Hash) }
      failed = checks.any? do |c|
        %w[FAILURE TIMED_OUT CANCELLED ACTION_REQUIRED STARTUP_FAILURE ERROR].include?(c["conclusion"]) ||
          %w[FAILURE ERROR].include?(c["state"])
      end
      pending = checks.any? do |c|
        (c.key?("status") && c["status"] != "COMPLETED") || %w[PENDING EXPECTED].include?(c["state"])
      end
      if failed then "CI failing"
      elsif pending then "CI pending"
      else "CI passing"
      end
    end
  end

  # --- page ---------------------------------------------------------------------------

  def embed(data)
    JSON.generate(data).gsub("<", "\\u003c").gsub(">", "\\u003e").gsub("&", "\\u0026")
        .gsub("\u2028", "\\u2028").gsub("\u2029", "\\u2029")
  end

  def csp(nonce)
    "default-src 'none'; script-src 'nonce-#{nonce}'; style-src 'nonce-#{nonce}'; " \
      "connect-src 'self'; img-src 'none'; base-uri 'none'; form-action 'none'"
  end

  # The page. `data` is nil for the live server (the script polls api/board)
  # and the board JSON for a snapshot.
  def page(nonce, data = nil)
    <<~HTML
      <!doctype html>
      <html lang="en">
      <head>
      <meta charset="utf-8">
      <meta name="viewport" content="width=device-width, initial-scale=1">
      <meta http-equiv="Content-Security-Policy" content="#{csp(nonce)}">
      <meta name="referrer" content="no-referrer">
      <title>Agent Board</title>
      <style nonce="#{nonce}">#{CSS}</style>
      </head>
      <body>
      <header class="top"><h1>Agent Board</h1><p id="count" class="summary"></p><p id="status" class="status"></p></header>
      <main id="board"></main>
      <footer id="errors"></footer>
      <script id="board-data" type="application/json">#{data ? embed(data) : 'null'}</script>
      <script nonce="#{nonce}">#{JS.sub('__POLL_MS__', (POLL_SECONDS * 1000).to_s)}</script>
      </body>
      </html>
    HTML
  end

  # Every color, type size and space on the page comes from this one :root
  # block, and every color is one of the 16 Nord values (an alpha byte is
  # allowed). test_board.py checks both and computes each text and mark pair's
  # WCAG contrast from it; change a token there, not inline.
  CSS = <<~'CSS'
    :root{
      color-scheme:dark;
      --bg:#2E3440;--surface:#3B4252;--rule:#434C5E;--rule-strong:#4C566A;
      --text:#ECEFF4;--text-2:#D8DEE9;--accent:#88C0D0;--link:#8FBCBB;
      --st-working:#88C0D0;--st-needs:#EBCB8B;--st-waiting:#B48EAD;--st-stalled:#D08770;
      --st-done:#A3BE8C;--st-failed:#BF616A;--st-queued:#81A1C1;--st-idle:#D8DEE9;
      --trace-off:#434C5E;--trace-on:#88C0D0;
      --font:"Avenir Next","Avenir","Hiragino Sans","Segoe UI","Noto Sans",system-ui,sans-serif;
      --mono:"SF Mono",ui-monospace,Menlo,Consolas,monospace;
      --fs-1:12px;--fs-2:13px;--fs-3:15px;--fs-4:18px;--fs-5:22px;
      --lh-tight:1.3;--lh:1.5;
      --s-0:2px;--s-1:4px;--s-2:8px;--s-3:12px;--s-4:16px;--s-5:24px;--s-6:32px;
      --edge:3px;--mark:9px;--page:1360px;
      --cols:minmax(0,1fr) 8.5rem 8.5rem 9.5rem 7.5rem;
    }
    *{box-sizing:border-box}
    html{background:var(--bg)}
    body{margin:0;background:var(--bg);color:var(--text);font-family:var(--font);font-size:var(--fs-3);
      line-height:var(--lh-tight);font-variant-numeric:tabular-nums;overflow-wrap:anywhere}
    .top,main,#errors{max-width:var(--page);padding-left:var(--s-5);padding-right:var(--s-5)}
    .top{display:flex;flex-wrap:wrap;align-items:baseline;column-gap:var(--s-5);row-gap:var(--s-1);
      padding-top:var(--s-5);padding-bottom:var(--s-4)}
    h1{font-size:var(--fs-5);font-weight:600;margin:0;letter-spacing:-0.01em}
    .summary{margin:0;color:var(--text-2);font-size:var(--fs-3)}
    .summary b{color:var(--text);font-weight:600}
    .summary .sep{margin-right:var(--s-3)}
    .status{margin:0 0 0 auto;color:var(--text-2);font-size:var(--fs-2)}
    main{padding-bottom:var(--s-6)}
    button{font:inherit;color:inherit;background:none;border:0;padding:0;margin:0;cursor:pointer;text-align:left}
    a{color:var(--link);text-decoration:none}
    a:hover{text-decoration:underline}
    :focus{outline:none}
    :focus-visible{outline:2px solid var(--accent);outline-offset:2px;border-radius:2px}
    .row:focus-visible{outline-offset:-2px}
    .ghost{border:1px solid var(--rule-strong);border-radius:4px;padding:var(--s-1) var(--s-3);color:var(--text-2);
      font-size:var(--fs-2)}
    .ghost:hover{border-color:var(--text-2);color:var(--text)}

    /* needs you: above every controller, one line when empty */
    .needs{margin:0 0 var(--s-5);border-left:var(--edge) solid var(--st-needs);padding:var(--s-2) 0 var(--s-2) var(--s-4)}
    .needs.none{border-left-color:var(--rule-strong);color:var(--text-2);font-size:var(--fs-2);padding:var(--s-1) 0 var(--s-1) var(--s-4)}
    .needs h2{margin:0 0 var(--s-2);font-size:var(--fs-4);font-weight:600;color:var(--st-needs)}
    .needs .row{border-top:0}
    .needs .row::before{display:none}
    .need{color:var(--text);line-height:var(--lh);margin-top:var(--s-1)}
    .tag{font-family:var(--mono);font-size:var(--fs-1);color:var(--text-2);border:1px solid var(--rule-strong);
      border-radius:3px;padding:0 var(--s-1);margin-right:var(--s-2);white-space:nowrap}

    /* shared columns: the column header and every row use --cols */
    .cols,.row{display:grid;grid-template-columns:var(--cols);column-gap:var(--s-4);align-items:start}
    .cols{color:var(--text-2);font-size:var(--fs-1);padding:0 var(--s-3) var(--s-1) calc(var(--s-3) + var(--edge))}
    .cols .r,.c-act{text-align:right}

    /* controller band */
    .group{margin-top:var(--s-5)}
    .group:first-of-type{margin-top:0}
    .group h2{margin:0;font-size:inherit;font-weight:inherit}
    .ghead{display:flex;flex-wrap:wrap;align-items:baseline;column-gap:var(--s-4);row-gap:var(--s-1);width:100%;
      background:var(--surface);border-radius:4px;padding:var(--s-3) var(--s-3) var(--s-3) var(--s-4)}
    .ghead .gtag{font-size:var(--fs-4);font-weight:600;color:var(--text)}
    .ghead .repos{font-size:var(--fs-3);color:var(--text)}
    .ghead .gkey{font-family:var(--mono);font-size:var(--fs-1);color:var(--text-2)}
    .ghead .counts{margin-left:auto;display:flex;flex-wrap:wrap;column-gap:var(--s-4);font-size:var(--fs-2);color:var(--text-2)}
    .ghead .counts b{color:var(--text);font-weight:600}
    .ghead .count{display:inline-flex;align-items:baseline;gap:var(--s-1)}
    .ghead .fold{color:var(--text-2);font-size:var(--fs-2);min-width:4.5em;text-align:right}
    .rows{margin-top:var(--s-1)}

    /* one task row */
    .row{position:relative;padding:var(--s-3) var(--s-3) var(--s-3) calc(var(--s-3) + var(--edge));
      border-top:1px solid var(--rule);cursor:pointer}
    .rows>.task:first-child>.row{border-top:0}
    .row:hover .title{color:var(--accent)}
    .row::before{content:"";position:absolute;left:0;top:var(--s-2);bottom:var(--s-2);width:var(--edge);border-radius:2px}
    .row.ph-stalled::before{background:var(--st-stalled)}
    .row.ph-needs::before{background:var(--st-needs)}
    .row.ph-error::before,.row.ph-retry::before{background:var(--st-failed)}
    .c-title{min-width:0}
    .title{font-weight:500;line-height:var(--lh-tight);display:-webkit-box;-webkit-box-orient:vertical;
      -webkit-line-clamp:2;line-clamp:2;overflow:hidden}
    .task.open .title{display:block;-webkit-line-clamp:unset}
    .sub{display:flex;column-gap:var(--s-3);margin-top:var(--s-1);font-size:var(--fs-2);color:var(--text-2);min-width:0}
    .sub .now{overflow:hidden;text-overflow:ellipsis;white-space:nowrap;min-width:0;flex:0 1 auto}
    .worker{font-family:var(--mono);font-size:var(--fs-1);color:var(--text-2);white-space:nowrap;flex:0 0 auto}
    .c-state{display:flex;align-items:baseline;gap:var(--s-2);font-size:var(--fs-2);min-width:0}
    .c-state .word{min-width:0}
    .c-prog{display:flex;align-items:center;gap:var(--s-2);font-size:var(--fs-2);padding-top:var(--s-1)}
    .c-prog .frac{color:var(--text-2);white-space:nowrap}
    .c-pr{font-size:var(--fs-2);display:flex;flex-wrap:wrap;align-items:baseline;column-gap:var(--s-2);min-width:0}
    .c-pr .prs{color:var(--text-2)}
    .c-pr .none,.c-prog .none{color:var(--text-2)}
    .c-act{display:flex;justify-content:flex-end;align-items:center;gap:var(--s-2);font-size:var(--fs-2);
      color:var(--text-2);padding-top:var(--s-0);white-space:nowrap}

    /* finished rows: one line each, behind one fold per band */
    .finished{display:block;width:100%;padding:var(--s-2) var(--s-3) var(--s-2) calc(var(--s-3) + var(--edge));
      color:var(--text-2);font-size:var(--fs-2);border-top:1px solid var(--rule)}
    .finished:hover{color:var(--text)}
    .compact .row{padding-top:var(--s-2);padding-bottom:var(--s-2)}
    .compact .title{-webkit-line-clamp:1;line-clamp:1;font-weight:400;font-size:var(--fs-2);color:var(--text-2)}
    .compact .sub{display:none}
    .compact.open .sub{display:flex}

    /* state marks: shape and color together, never color alone */
    .mark{flex:0 0 auto;display:inline-block;width:var(--mark);height:var(--mark);position:relative;top:0}
    .m-working,.m-doing{border-radius:50%;background:var(--st-working)}
    .m-queued{border-radius:50%;border:2px solid var(--st-queued)}
    .m-waiting,.m-pending{border-radius:50%;border:2px solid var(--st-waiting)}
    .m-pending{border-color:var(--st-needs)}
    .m-stalled{background:var(--st-stalled);border-radius:1px}
    .m-needs{background:var(--st-needs);transform:rotate(45deg) scale(.85);border-radius:1px}
    .m-done,.m-passing{width:5px;height:10px;border:solid var(--st-done);border-width:0 2px 2px 0;
      transform:translate(2px,-1px) rotate(45deg);margin-right:var(--s-0)}
    .m-error,.m-retry,.m-failed,.m-failing{width:10px;height:10px}
    .m-error::before,.m-error::after,.m-retry::before,.m-retry::after,.m-failed::before,.m-failed::after,
    .m-failing::before,.m-failing::after{content:"";position:absolute;left:4px;top:-1px;width:2px;height:12px;
      background:var(--st-failed);transform:rotate(45deg)}
    .m-error::after,.m-retry::after,.m-failed::after,.m-failing::after{transform:rotate(-45deg)}
    .m-cancelled{height:2px;background:var(--st-idle);top:-3px}
    .m-todo{border-radius:50%;border:1.5px solid var(--st-idle)}

    /* progress bar: supplementary to the done/total figure next to it */
    .bar{display:flex;flex:0 0 auto;width:4.5rem;height:4px;background:var(--rule);border-radius:2px;overflow:hidden}
    .bar span{height:100%}
    .bar .b-done{background:var(--st-done)}.bar .b-doing{background:var(--st-working)}
    .bar .b-failed{background:var(--st-failed)}

    /* activity trace: one bin per 5 minutes over the last hour, oldest left */
    .trace{display:inline-flex;gap:var(--s-0);align-items:flex-end;height:12px}
    .trace{height:14px}
    .trace span{width:4px;height:3px;background:var(--trace-off);border-radius:1px}
    .trace span.on{height:14px;background:var(--trace-on)}
    .trace span.lo{height:8px;background:var(--trace-on)}

    /* expanded detail: one column by default (now, checklist, last report, timeline, facts);
       two top-aligned columns from 900px: left = now, checklist, last report, facts; right = timeline */
    .detail{display:grid;grid-template-columns:minmax(0,1fr);align-items:start;column-gap:var(--s-6);row-gap:var(--s-3);
      padding:var(--s-1) var(--s-3) var(--s-5) calc(var(--s-3) + var(--edge));max-width:84rem}
    .dleft,.dright{display:contents}
    .part{display:grid;grid-template-columns:7rem minmax(0,1fr);column-gap:var(--s-4);min-width:0;overflow-wrap:anywhere}
    .p-now{order:1}.p-check{order:2}.p-report{order:3}.p-timeline{order:4}.p-facts{order:5}
    .detail.fresh{animation:reveal .16s ease-out}
    @keyframes reveal{from{opacity:0}to{opacity:1}}
    .detail h3{margin:0;font-size:var(--fs-2);font-weight:500;color:var(--text-2);padding-top:var(--s-0)}
    .detail .body{min-width:0;font-size:var(--fs-2)}
    .detail p{margin:0;line-height:var(--lh)}
    .detail .meta{color:var(--text-2);margin-bottom:var(--s-1)}
    .detail .lead{font-size:var(--fs-3);color:var(--text);line-height:var(--lh)}
    .detail ul{list-style:none;margin:0;padding:0}
    .detail ul ul{padding-left:var(--s-5);margin-top:var(--s-1)}
    .check li{display:flex;align-items:baseline;column-gap:var(--s-2);flex-wrap:wrap;margin:var(--s-0) 0}
    .check li>ul{flex-basis:100%}
    .check .text{flex:1 1 0;min-width:0;line-height:var(--lh)}
    .check .text.clip{overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
    .check button.text:hover{color:var(--text)}
    .check .res{color:var(--text-2)}
    .more{margin-top:var(--s-2)}
    .tl li{display:grid;grid-template-columns:3.2rem var(--mark) minmax(0,1fr);column-gap:var(--s-2);margin:var(--s-0) 0;
      align-items:baseline}
    .tl time{color:var(--text-2)}
    .tl .mark{width:7px;height:7px;border-radius:50%}
    .t-green{background:var(--st-done)}.t-blue{background:var(--st-working)}.t-red{background:var(--st-failed)}
    .t-amber{background:var(--st-needs)}.t-grey{background:var(--st-idle)}.t-teal,.t-purple{background:var(--link)}
    .tl .text{line-height:var(--lh)}
    dl{display:grid;grid-template-columns:max-content minmax(0,1fr);column-gap:var(--s-4);row-gap:var(--s-0);margin:0}
    dt{color:var(--text-2)}dd{margin:0;min-width:0}
    dd .pr{margin-right:var(--s-3)}

    .foot{margin-top:var(--s-5)}
    #errors{color:var(--text);font-size:var(--fs-2);padding-bottom:var(--s-5)}
    #errors div{border-left:var(--edge) solid var(--st-failed);padding-left:var(--s-3);margin:var(--s-1) 0}

    @media (min-width:900px){
      .detail{grid-template-columns:minmax(0,3fr) minmax(0,2fr)}
      .dleft{display:flex;flex-direction:column;row-gap:var(--s-3);min-width:0}
      .dright{display:block;min-width:0}
      .p-timeline{grid-template-columns:minmax(0,1fr);row-gap:var(--s-1)}
    }
    @media (max-width:760px){
      .top,main,#errors{padding-left:var(--s-3);padding-right:var(--s-3)}
      .status{margin-left:0;flex-basis:100%}
      .cols{display:none}
      .row{display:flex;flex-wrap:wrap;align-items:baseline;column-gap:var(--s-3);row-gap:var(--s-2)}
      .row::after{content:"";order:2;flex-basis:100%;height:0}
      .c-title{order:0;flex:1 1 0}.c-act{order:1;flex:0 0 auto;padding-top:0}
      .c-state{order:3;flex:0 1 auto}.c-prog{order:4;padding-top:0}.c-pr{order:5;margin-left:auto}
      .trace{display:none}
      .compact .c-state,.compact .c-prog,.compact .c-pr,.compact .row::after{display:none}
      .compact.open .c-state,.compact.open .c-prog,.compact.open .c-pr{display:flex}
      .compact.open .row::after{display:block}
      .ghead .counts{margin-left:0;flex-basis:100%}
      .ghead .fold{position:absolute;right:var(--s-3);top:var(--s-3)}
      .ghead{position:relative;padding-right:calc(var(--s-6) + var(--s-5))}
      .detail{row-gap:var(--s-1)}
      .part{grid-template-columns:minmax(0,1fr)}
      .detail h3{padding-top:var(--s-2)}
      .sub{flex-wrap:wrap}
    }
    @media (prefers-reduced-motion:reduce){
      *,*::before,*::after{animation:none!important;transition:none!important;scroll-behavior:auto!important}
    }
  CSS

  # Builds every node with createElement + textContent; never innerHTML.
  JS = <<~'JS'
    (function () {
      "use strict";
      var POLL_MS = __POLL_MS__;
      var TIMELINE_SHOWN = 6, CHECKLIST_SHOWN = 12, CLIP_CHARS = 90;
      var embedded = JSON.parse(document.getElementById("board-data").textContent);
      var opened = {}, fresh = {}, longTimeline = {}, longChecklist = {}, fullText = {};
      var folded = {}, finishedOpen = {}, showAllIdle = false, last = null, receivedAt = 0, keyed = {};
      var PR = /^https:\/\/github\.com\/[A-Za-z0-9-]+\/[A-Za-z0-9._-]+\/pull\/[0-9]+$/;
      var WORDS = { needs: "needs you", waiting: "waiting", stalled: "stalled", working: "working",
                    queued: "queued", retry: "retrying", error: "error", done: "done", cancelled: "cancelled" };
      // #t=<token> is the per-run token board.rb printed; #<task-id> (also
      // after the token, as #t=...&<task-id>) opens that task's row.
      var token = "";
      (typeof location === "undefined" ? "" : location.hash.slice(1)).split("&").forEach(function (part) {
        if (/^t=[0-9a-f]{32}$/.test(part)) token = part.slice(2);
        else if (/^[0-9a-f]{16}$/.test(part)) opened[part] = true;
      });

      function el(tag, cls, text) {
        var node = document.createElement(tag);
        if (cls) node.className = cls;
        if (text !== undefined && text !== null) node.textContent = String(text);
        return node;
      }
      function add(parent) {
        for (var i = 1; i < arguments.length; i++) if (arguments[i]) parent.appendChild(arguments[i]);
        return parent;
      }
      // A control that keeps keyboard focus across the 5-second re-render.
      function keyOf(node, key) {
        node.setAttribute("data-key", key);
        keyed[key] = node;
        return node;
      }
      function button(cls, text, key, onClick, expanded) {
        var b = keyOf(el("button", cls, text), key);
        b.type = "button";
        if (expanded !== undefined) b.setAttribute("aria-expanded", expanded ? "true" : "false");
        b.addEventListener("click", function (e) { e.stopPropagation(); onClick(); render(last); });
        return b;
      }
      function nowMs() {
        var base = Date.parse(last && last.generated_at);
        return isNaN(base) ? Date.now() : base + (embedded ? 0 : Date.now() - receivedAt);
      }
      function ago(iso) {
        var t = Date.parse(iso);
        if (isNaN(t)) return "";
        var s = Math.max(0, Math.round((nowMs() - t) / 1000));
        if (s < 60) return s + " s";
        if (s < 3600) return Math.floor(s / 60) + " min";
        if (s < 86400) return Math.floor(s / 3600) + " h";
        return Math.floor(s / 86400) + " d";
      }
      function stamp(iso) {
        var d = new Date(iso);
        if (isNaN(d.getTime())) return iso;
        return d.getFullYear() + "-" + ("0" + (d.getMonth() + 1)).slice(-2) + "-" + ("0" + d.getDate()).slice(-2) + " " + hhmm(iso);
      }
      function hhmm(iso) {
        var d = new Date(iso);
        if (isNaN(d.getTime())) return "";
        return ("0" + d.getHours()).slice(-2) + ":" + ("0" + d.getMinutes()).slice(-2);
      }
      function span(from, to) {
        var a = Date.parse(from), b = to ? Date.parse(to) : nowMs();
        if (isNaN(a) || isNaN(b)) return "";
        var m = Math.max(0, Math.round((b - a) / 60000));
        return m < 120 ? m + " min" : Math.round(m / 60) + " h";
      }
      function plural(n, one, many) { return n + " " + (n === 1 ? one : many); }
      function mark(kind) { return el("span", "mark m-" + kind); }
      function bar(p) {
        var node = el("div", "bar");
        if (!p || !p.total) return node;
        ["done", "doing", "failed"].forEach(function (k) {
          if (!p[k]) return;
          var seg = el("span", "b-" + k);
          seg.style.width = (100 * p[k] / p.total) + "%";
          node.appendChild(seg);
        });
        return node;
      }
      function prLink(pr, text) {
        var a = el("a", "pr", text);
        if (PR.test(pr.url)) {
          a.href = pr.url;
          a.target = "_blank";
          a.rel = "noopener noreferrer";
        }
        a.addEventListener("click", function (e) { e.stopPropagation(); });
        return a;
      }
      function stateWord(row) {
        if (row.phase === "waiting") return "waiting on " + row.waiting_on;
        if (row.phase === "stalled") return "stalled " + ago(row.activity_at);
        return WORDS[row.phase] || row.state;
      }
      // The row's second line: the text before the first URL (the detail keeps
      // the full text), without a dangling ":" or "(".
      function brief(text) {
        var cut = text.search(/https?:\/\//);
        if (cut < 0) return text;
        var head = text.slice(0, cut).replace(/[\s:;,(\[-]+$/, "");
        return head || text;
      }
      function nowText(now) {
        if (!now) return "";
        if (now.kind === "waiting") return "Waiting on " + (now.on || "someone") + ": " + now.text;
        if (now.kind === "step") return "Step " + now.step + ": " + now.text;
        return now.text;
      }

      // --- the row: title, state, progress, pull request, activity
      function rowNode(row, inNeeds) {
        var isOpen = !!opened[row.id];
        var wrap = el("div", "task" + (row.section === "idle" ? " compact" : "") + (isOpen ? " open" : ""));
        var line = keyOf(el("div", "row ph-" + row.phase), "row:" + row.id);
        line.tabIndex = 0;
        line.setAttribute("role", "button");
        line.setAttribute("aria-expanded", isOpen ? "true" : "false");

        var title = el("div", "c-title");
        title.appendChild(el("div", "title", row.topic));
        var sub = el("div", "sub");
        if (inNeeds) {
          var tag = el("span", "tag", row.controller_tag);
          tag.setAttribute("title", row.owner || "no controller key");
          sub.appendChild(tag);
        }
        // The state column already names who a worker waits on.
        if (!inNeeds && row.now) sub.appendChild(el("span", "now", brief(row.now.kind === "waiting" ? row.now.text : nowText(row.now))));
        sub.appendChild(el("span", "worker", row.agent));
        title.appendChild(sub);
        if (inNeeds && row.need) title.appendChild(el("div", "need", row.need));

        var state = add(el("div", "c-state"), mark(row.phase), el("span", "word", stateWord(row)));
        // The checklist, else the latest step i/n; acceptance criteria are not progress.
        var p = row.progress;
        var prog = el("div", "c-prog");
        if (p && p.total) {
          var frac = el("span", "frac", p.done + "/" + p.total);
          if (p.source === "step") frac.setAttribute("title", "latest step");
          add(prog, bar(p), frac);
        } else {
          prog.appendChild(el("span", "none", "no progress recorded"));
        }

        var prCell = el("div", "c-pr");
        if (row.prs.length) {
          var pr = row.prs[row.prs.length - 1];
          var label = pr.label.slice(pr.label.lastIndexOf("#"));
          prCell.appendChild(prLink(pr, label));
          prCell.appendChild(el("span", "prs", pr.status || "state unknown"));
          if (pr.ci) {
            var ci = mark(pr.ci);
            ci.setAttribute("title", "CI " + pr.ci);
            prCell.appendChild(ci);
          }
          if (row.prs.length > 1) prCell.appendChild(el("span", "prs", "+" + (row.prs.length - 1)));
        } else {
          prCell.appendChild(el("span", "none", "no PR"));
        }

        var act = el("div", "c-act");
        var trace = el("span", "trace");
        trace.setAttribute("aria-hidden", "true");
        (row.trace || []).forEach(function (n) { trace.appendChild(el("span", n >= 3 ? "on" : n > 0 ? "lo" : null)); });
        var when = el("time", null, ago(row.activity_at || row.updated_at));
        if (row.activity_at || row.updated_at) when.setAttribute("datetime", row.activity_at || row.updated_at);
        add(act, trace, when);

        add(line, title, state, prog, prCell, act);
        function toggle() {
          opened[row.id] = !opened[row.id];
          if (opened[row.id]) fresh[row.id] = true;
          render(last);
        }
        line.addEventListener("click", toggle);
        line.addEventListener("keydown", function (e) {
          if (e.key === "Enter" || e.key === " ") { e.preventDefault(); toggle(); }
        });
        wrap.appendChild(line);
        if (isOpen) wrap.appendChild(detail(row));
        return wrap;
      }

      // --- the detail: two columns when wide (left: now, checklist, last report, facts; right: timeline),
      // one column in the order now, checklist, last report, timeline, facts when narrow (CSS order)
      function part(col, name, label, body) {
        col.appendChild(add(el("div", "part p-" + name), el("h3", null, label), add(el("div", "body"), body)));
      }
      function checkItems(row, items, path) {
        var ul = el("ul", path ? null : "check");
        items.forEach(function (item, i) {
          var key = row.id + ":" + path + i;
          var li = el("li");
          li.appendChild(mark(item.state));
          var text;
          if (item.text.length > CLIP_CHARS) {
            text = button("text" + (fullText[key] ? "" : " clip"), item.text, "clip:" + key,
                          function () { fullText[key] = !fullText[key]; }, !!fullText[key]);
            text.setAttribute("title", fullText[key] ? "Show one line" : "Show the full text");
          } else {
            text = el("span", "text", item.text);
          }
          li.appendChild(text);
          if (item.mark) li.appendChild(el("span", "res", item.mark));
          if (item.children && item.children.length) li.appendChild(checkItems(row, item.children, path + i + "."));
          ul.appendChild(li);
        });
        return ul;
      }
      function detail(row) {
        var box = el("div", "detail" + (fresh[row.id] ? " fresh" : ""));
        var left = el("div", "dleft"), right = el("div", "dright");
        add(box, left, right);
        delete fresh[row.id];
        var t = row.tasks, p = t.progress;

        var now = el("div");
        now.appendChild(el("p", "lead", row.now ? nowText(row.now) : "No report yet."));
        var status = row.facts.filter(function (f) { return f.label === "Status"; })[0];
        if (status) now.appendChild(el("p", "meta", "Status file: " + status.value + (status.at ? " " + ago(status.at) + " ago" : "")));
        if (row.activity_at) now.appendChild(el("p", "meta", "Last recorded activity " + ago(row.activity_at) + " ago, at " + hhmm(row.activity_at)));
        part(left, "now", "Now", now);

        var list = el("div");
        var summary;
        if (t.source === "checklist") {
          summary = p.total ? p.done + " of " + p.total + " done" : "No items";
        } else {
          var marked = t.items.filter(function (i) { return i.mark; });
          summary = plural(t.items.length, "acceptance criterion", "acceptance criteria") + (marked.length
            ? ": " + ["pass", "fail", "unverified"].map(function (m) {
                return marked.filter(function (i) { return i.mark === m; }).length + " " + m;
              }).join(", ")
            : ", not yet checked by an envelope");
        }
        if (t.started_at) summary += ", " + (t.ended_at ? "took " : "running for ") + span(t.started_at, t.ended_at);
        list.appendChild(el("p", "meta", summary));
        if (t.note) list.appendChild(el("p", "meta", t.note));
        var items = longChecklist[row.id] ? t.items : t.items.slice(0, CHECKLIST_SHOWN);
        list.appendChild(checkItems(row, items, ""));
        if (t.items.length > CHECKLIST_SHOWN) {
          list.appendChild(add(el("div", "more"), button("ghost", longChecklist[row.id] ? "Show the first " + CHECKLIST_SHOWN + " items"
            : "Show all " + t.items.length + " items", "checklist:" + row.id,
            function () { longChecklist[row.id] = !longChecklist[row.id]; })));
        }
        part(left, "check", t.source === "checklist" ? "Checklist" : "Checklist: acceptance criteria", list);

        var report = el("div");
        if (row.last_report) {
          report.appendChild(el("p", "meta", hhmm(row.last_report.at) + ", " + ago(row.last_report.at) + " ago, " + row.last_report.kind));
          report.appendChild(el("p", null, row.last_report.text));
        } else {
          report.appendChild(el("p", "meta", "None yet."));
        }
        part(left, "report", "Last report", report);

        var tl = el("div");
        var limit = longTimeline[row.id] ? row.timeline.length : TIMELINE_SHOWN;
        if (row.timeline.length > TIMELINE_SHOWN) {
          tl.appendChild(el("p", "meta", longTimeline[row.id] ? "All " + row.timeline.length + " events, newest first"
            : "Newest " + TIMELINE_SHOWN + " of " + row.timeline.length + " events"));
        }
        if (!row.timeline.length) tl.appendChild(el("p", "meta", "No events recorded yet."));
        var ul = el("ul", "tl");
        row.timeline.slice(0, limit).forEach(function (entry) {
          var time = el("time", null, hhmm(entry.at));
          time.setAttribute("datetime", entry.at);
          ul.appendChild(add(el("li"), time, el("span", "mark t-" + entry.color), el("span", "text", entry.text)));
        });
        if (row.timeline.length) tl.appendChild(ul);
        if (row.timeline.length > TIMELINE_SHOWN) {
          tl.appendChild(add(el("div", "more"), button("ghost", longTimeline[row.id] ? "Show the newest " + TIMELINE_SHOWN
            : "Show all " + row.timeline.length + " events", "timeline:" + row.id,
            function () { longTimeline[row.id] = !longTimeline[row.id]; })));
        }
        part(right, "timeline", "Timeline", tl);

        var dl = el("dl");
        var prs = el("dd");
        if (!row.prs.length) prs.textContent = "none recorded";
        row.prs.forEach(function (pr) {
          add(prs, add(el("span", "pr"), prLink(pr, pr.label), pr.state ? el("span", null, " " + pr.state) : null));
        });
        add(dl, el("dt", null, "Pull requests"), prs, el("dt", null, "Worker"), el("dd", null, row.agent));
        if (row.repo) add(dl, el("dt", null, "Repository"), el("dd", null, row.repo));
        row.facts.forEach(function (f) {
          if (f.label === "Status") return;
          add(dl, el("dt", null, f.label), el("dd", null, f.value + (f.at ? " " + ago(f.at) + " ago" : "")));
        });
        part(left, "facts", "Facts", dl);
        return box;
      }

      // --- a controller band
      function countSpan(n, word, kind) {
        if (!n && kind !== "working") return null;
        return add(el("span", "count"), kind ? mark(kind) : null, el("b", null, n), el("span", null, word));
      }
      function groupNode(group, rows) {
        var key = group.owner || "";
        var isFolded = !!folded[key];
        var live = rows.filter(function (r) { return r.section !== "idle"; });
        var idle = rows.filter(function (r) { return r.section === "idle"; });
        var c = group.counts;
        var sec = el("section", "group");
        var head = button("ghead", null, "group:" + key, function () { folded[key] = !folded[key]; }, !isFolded);
        var gtag = el("span", "gtag", group.tag);
        var gkey = el("span", "gkey", group.label);
        gkey.setAttribute("title", group.owner || "tasks without a controller key");
        var counts = add(el("span", "counts"),
          countSpan(c.working, "working", "working"), countSpan(c.stalled, "stalled", "stalled"),
          countSpan(c.waiting, "waiting", "waiting"), countSpan(c.needs, "need you", "needs"),
          countSpan(idle.length, "finished", null));
        add(head, gtag, group.repos.length ? el("span", "repos", group.repos.join(", ")) : null, gkey, counts,
            el("span", "fold", isFolded ? "Show" : "Hide"));
        sec.appendChild(add(el("h2"), head));
        if (isFolded) return sec;
        var list = el("div", "rows");
        live.forEach(function (row) { list.appendChild(rowNode(row, false)); });
        if (idle.length) {
          var anyOpen = idle.some(function (r) { return opened[r.id]; });
          var showIdle = finishedOpen[key] || anyOpen;
          list.appendChild(button("finished", (showIdle ? "Hide " : "Show ") + plural(idle.length, "finished task", "finished tasks") +
            (showAllIdle ? "" : " from the last 24 hours"), "finished:" + key,
            function () { finishedOpen[key] = !showIdle; idle.forEach(function (r) { if (showIdle) delete opened[r.id]; }); }, !!showIdle));
          if (showIdle) idle.forEach(function (row) { list.appendChild(rowNode(row, false)); });
        }
        sec.appendChild(list);
        return sec;
      }

      function columns() {
        return add(el("div", "cols"), el("span", null, "Task"), el("span", null, "State"), el("span", null, "Progress"),
                   el("span", null, "Pull request"), el("span", "r", "Last activity"));
      }

      function render(data) {
        if (!data) return;
        var focusKey = document.activeElement && document.activeElement.getAttribute
          ? document.activeElement.getAttribute("data-key") : null;
        keyed = {};
        var nodes = [], hidden = 0, totals = { working: 0, stalled: 0, waiting: 0 };

        var needs = el("section", "needs" + (data.needs_you.length ? "" : " none"));
        if (data.needs_you.length) {
          needs.appendChild(el("h2", null, plural(data.needs_you.length, "task needs you", "tasks need you")));
          data.needs_you.forEach(function (row) { needs.appendChild(rowNode(row, true)); });
        } else {
          needs.appendChild(el("p", null, "Nothing needs you right now."));
        }
        nodes.push(needs);

        var bands = [];
        data.groups.forEach(function (group) {
          var rows = group.rows.filter(function (r) { return r.section !== "idle" || showAllIdle || r.recent || opened[r.id]; });
          hidden += group.rows.length - rows.length;
          totals.working += group.counts.working;
          totals.stalled += group.counts.stalled;
          totals.waiting += group.counts.waiting;
          if (!rows.length) return;
          bands.push(groupNode(group, rows));
        });
        if (bands.length) nodes.push(columns());
        nodes = nodes.concat(bands);
        if (hidden || showAllIdle) {
          nodes.push(add(el("div", "foot"), button("ghost", showAllIdle ? "Show only the last 24 hours"
            : "Show all finished tasks (" + hidden + " older than 24 hours)", "idle",
            function () { showAllIdle = !showAllIdle; })));
        }

        var count = document.getElementById("count");
        count.replaceChildren(
          add(el("span", "sep"), el("b", null, totals.working), el("span", null, " working")),
          add(el("span", "sep"), el("b", null, totals.stalled), el("span", null, " stalled")),
          add(el("span", "sep"), el("b", null, totals.waiting), el("span", null, " waiting")),
          add(el("span", "sep"), el("b", null, data.needs_you.length), el("span", null, data.needs_you.length === 1 ? " needs you" : " need you")));
        var board = document.getElementById("board");
        board.replaceChildren.apply(board, nodes);
        var errors = document.getElementById("errors");
        errors.replaceChildren();
        data.errors.forEach(function (e) { errors.appendChild(el("div", null, "Unreadable task " + e.task + ": " + e.reason)); });
        if (focusKey && keyed[focusKey] && keyed[focusKey].focus) keyed[focusKey].focus();
      }
      function status(text) { document.getElementById("status").textContent = text; }
      function poll() {
        if (!token) {
          status("Open the URL board.rb printed: it carries this run's access token (#t=...).");
          return;
        }
        fetch("api/board", { cache: "no-store", credentials: "same-origin", headers: { "X-Board-Token": token } })
          .then(function (r) {
            if (r.status === 403) throw new Error("token refused; open the URL board.rb printed for this run");
            if (!r.ok) throw new Error("HTTP " + r.status);
            return r.json();
          })
          .then(function (data) {
            last = data; receivedAt = Date.now(); render(data);
            status("Live, updated " + hhmm(data.generated_at) + ", every " + data.poll_seconds + " s" + (data.gh ? "" : ", PR state off"));
          })
          .catch(function (e) { status("Refresh failed (" + e.message + "); retrying."); })
          .then(function () { setTimeout(poll, POLL_MS); });
      }
      if (embedded) {
        last = embedded;
        render(embedded);
        status("Snapshot of " + stamp(embedded.generated_at) + ", not live");
      } else {
        poll();
      }
    })();
  JS

  # --- server -----------------------------------------------------------------------

  def headers(res, type, nonce = nil)
    res["Content-Type"] = type
    res["Cache-Control"] = "no-store"
    res["X-Content-Type-Options"] = "nosniff"
    res["Referrer-Policy"] = "no-referrer"
    res["X-Frame-Options"] = "DENY"
    res["Content-Security-Policy"] = nonce ? "#{csp(nonce)}; frame-ancestors 'none'" : "default-src 'none'; frame-ancestors 'none'"
  end

  # Constant time for equal lengths; the token's length (32 hex) is public.
  def token_match?(given, token)
    return false unless given.is_a?(String) && token.is_a?(String) && given.bytesize == token.bytesize

    diff = 0
    given.bytes.zip(token.bytes) { |a, b| diff |= a ^ b }
    diff.zero?
  end

  def handle(req, res, root, prs, token)
    unless loopback_host?(req["host"])
      headers(res, "text/plain; charset=utf-8")
      res.status = 403
      res.body = "Host must be localhost, 127.0.0.1 or [::1]\n"
      return
    end
    unless req.request_method == "GET"
      headers(res, "text/plain; charset=utf-8")
      res.status = 405
      res["Allow"] = "GET"
      res.body = "only GET\n"
      return
    end
    case req.path
    when "/"
      nonce = SecureRandom.hex(16)
      headers(res, "text/html; charset=utf-8", nonce)
      res.body = page(nonce)
    when "/api/board"
      unless token_match?(req["x-board-token"], token)
        headers(res, "text/plain; charset=utf-8")
        res.status = 403
        res.body = "missing or wrong X-Board-Token; open the URL board.rb printed\n"
        return
      end
      headers(res, "application/json; charset=utf-8")
      res.body = JSON.generate(board(root, prs))
    else
      headers(res, "text/plain; charset=utf-8")
      res.status = 404
      res.body = "not found\n"
    end
  end

  def serve(options, root, prs)
    begin
      require "webrick"
    rescue LoadError
      warn "board.rb: the webrick gem is missing for #{RbConfig.ruby}; install it with `gem install webrick` (the claude-code cookbook does this)"
      exit 1
    end

    # 128 bits, generated here and printed once; never in argv, a file or a log.
    token = SecureRandom.hex(16)
    # Every request, including `OPTIONS *` that WEBrick would answer itself,
    # goes through handle(): Host check, then GET only, then the token.
    server_class = Class.new(WEBrick::HTTPServer) do
      define_method(:service) { |req, res| Board.handle(req, res, root, prs, token) }
    end
    server = server_class.new(
      BindAddress: options[:bind], Port: options[:port], DoNotReverseLookup: true,
      Logger: WEBrick::Log.new($stderr, WEBrick::Log::WARN), AccessLog: []
    )
    port = server.listeners.first.addr[1]
    host = options[:bind].include?(":") ? "[#{options[:bind]}]" : options[:bind]
    %w[INT TERM].each { |signal| trap(signal) { server.shutdown } }
    $stdout.puts "Agent Board: http://#{host}:#{port}/#t=#{token} (state #{root}; #{prs.enabled? ? 'gh on' : 'gh off'}; Ctrl-C stops)"
    $stdout.flush
    server.start
  ensure
    prs&.stop
  end

  def inside?(path, root)
    real = File.expand_path(path)
    dir = File.dirname(real)
    dir = File.realpath(dir) if File.directory?(dir)
    candidate = File.join(dir, File.basename(real))
    candidate == root || candidate.start_with?("#{root}/")
  end

  def snapshot(out, root, prs)
    abort "board.rb: --snapshot must be outside the state directory #{root}" if inside?(out, root)

    html = page(SecureRandom.hex(16), board(root, prs))
    dir = File.dirname(File.expand_path(out))
    temporary = File.join(dir, ".board-#{SecureRandom.hex(6)}.tmp")
    File.open(temporary, File::WRONLY | File::CREAT | File::EXCL | File::NOFOLLOW, 0o600) { |f| f.write(html) }
    File.rename(temporary, File.expand_path(out))
    $stdout.puts "Agent Board snapshot: #{File.expand_path(out)}"
  ensure
    File.unlink(temporary) if temporary && File.exist?(temporary)
  end

  def main(argv)
    options = { port: DEFAULT_PORT, bind: "127.0.0.1", gh: true, state_dir: nil, snapshot: nil, dump: false }
    parser = OptionParser.new do |o|
      o.banner = "Usage: board.rb [--port N] [--bind ADDR] [--no-gh] [--state-dir DIR] [--snapshot OUT.html | --dump-json]"
      o.on("--port N", Integer, "TCP port (default #{DEFAULT_PORT}; 0 picks a free one)") { |v| options[:port] = v }
      o.on("--bind ADDR", "Loopback address to listen on (default 127.0.0.1; also 127.0.0.0/8 or ::1)") { |v| options[:bind] = v }
      o.on("--[no-]gh", "Look up pull request state with gh (default on)") { |v| options[:gh] = v }
      o.on("--state-dir DIR", "Ledger root (default $COS_STATE_DIR, then ~/.local/state/chief-of-staff)") { |v| options[:state_dir] = v }
      o.on("--snapshot OUT", "Write one self-contained HTML page to OUT and exit") { |v| options[:snapshot] = v }
      o.on("--dump-json", "Print the board JSON and exit") { options[:dump] = true }
    end
    begin
      parser.parse!(argv)
      raise OptionParser::InvalidArgument, argv.join(" ") unless argv.empty?
    rescue OptionParser::ParseError => e
      warn "board.rb: #{e.message}"
      exit 2
    end
    unless loopback_address?(options[:bind])
      warn "board.rb: --bind must be a loopback address (127.0.0.0/8 or ::1), not #{options[:bind].inspect}"
      exit 2
    end
    unless options[:port].between?(0, 65_535)
      warn "board.rb: --port must be 0 to 65535"
      exit 2
    end
    root = File.expand_path(options[:state_dir] || ENV["COS_STATE_DIR"] || "~/.local/state/chief-of-staff")
    unless File.directory?(root)
      warn "board.rb: state directory #{root} does not exist"
      exit 2
    end
    root = File.realpath(root)

    if options[:snapshot]
      snapshot(options[:snapshot], root, PrCache.new(enabled: options[:gh], background: false))
    elsif options[:dump]
      $stdout.puts JSON.pretty_generate(board(root, PrCache.new(enabled: options[:gh], background: false)))
    else
      serve(options, root, PrCache.new(enabled: options[:gh]))
    end
  end
end

Board.main(ARGV) if $PROGRAM_NAME == __FILE__
