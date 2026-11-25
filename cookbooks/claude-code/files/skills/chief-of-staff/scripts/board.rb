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
    digest: 16 * 1024, prompt: 16 * 1024
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
    (state_file && state_file["milestones"].is_a?(Array) ? state_file["milestones"] : []).each do |m|
      next unless m.is_a?(Hash) && m["kind"] == "pr" && m["url"].is_a?(String) && (match = PR_URL.match(m["url"]))
      next if records.any? { |r| r[:url] == m["url"] }

      records << { url: m["url"], label: "#{match[2]}##{match[3]}", added_at: nil }
    end
    pr_list = records.map do |r|
      info = prs.lookup(r[:url])
      { url: r[:url], label: r[:label], state: info && info[:text], merged: info && info[:merged] }
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
    (state_file && state_file["milestones"].is_a?(Array) ? state_file["milestones"] : []).last(40).each do |m|
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

    # --- facts
    route = str(attempt["route"], 20)
    terminal = str(attempt["terminal_id"], 80) || str(attempt["pane"], 80)
    facts = []
    facts << { label: "PR", value: pr_list.empty? ? "none recorded" : pr_list.map { |p| [p[:label], p[:state]].compact.join(" · ") }.join(", ") }
    facts << { label: "Lane", value: [route || "?", terminal ? "terminal #{terminal}" : nil].compact.join(" · ") }
    facts << if state_file
               { label: "Status", value: "#{status || 'unknown'} · file updated", at: iso(status_at) }
             elsif str(attempt["kind"], 20) == "codex"
               { label: "Status", value: "no state file (Codex worker)" }
             else
               { label: "Status", value: "no state file" }
             end
    facts << { label: "Ledger", value: "#{state} · attempt #{number} of #{task['max_attempts'].is_a?(Integer) ? task['max_attempts'] : '?'}" }
    facts << { label: "Owner", value: owner || "?" }
    facts << { label: "Task", value: id }
    facts << { label: "Checklist", value: checklist_error } if checklist_error

    {
      id: id, topic: topic, owner: owner, state: state, section: section, need: need,
      color: if section == "needs_you" then "amber"
             elsif status == "error" || state == "retry" then "red"
             elsif section == "working" then (working ? "blue" : "teal")
             else state_color(state)
             end,
      agent: str(attempt["agent"], 120) || str(attempt["kind"], 20) || "(no worker yet)",
      kind: str(attempt["kind"], 20), attempt: number,
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
    rows.sort_by! { |r| [r[:working] ? 0 : 1, -(time(r[:updated_at])&.to_f || 0)] }
    sections = { needs_you: [], working: [], idle: [] }
    rows.each { |r| sections[r[:section].to_sym] << r }
    { generated_at: iso(now), poll_seconds: POLL_SECONDS, state_dir: File.basename(root),
      gh: prs.enabled?, sections: sections, errors: errors }
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
      { text: parts.join(" · "), merged: merged }
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
      <header><h1>Agent Board</h1><div id="count" class="count"></div><div id="status" class="status"></div></header>
      <main id="board"></main>
      <footer id="errors"></footer>
      <script id="board-data" type="application/json">#{data ? embed(data) : 'null'}</script>
      <script nonce="#{nonce}">#{JS.sub('__POLL_MS__', (POLL_SECONDS * 1000).to_s)}</script>
      </body>
      </html>
    HTML
  end

  CSS = <<~CSS
    :root{color-scheme:dark;--bg:#0f1115;--panel:#161a21;--line:#252b35;--fg:#d7dce4;--dim:#8a93a3;
    --green:#3fb950;--blue:#4c8dff;--red:#f05252;--amber:#e3a008;--grey:#5b6472;--teal:#2bb3a3;--purple:#a371f7}
    *{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--fg);
    font:13px/1.4 -apple-system,BlinkMacSystemFont,"Segoe UI",system-ui,sans-serif}
    header{display:flex;align-items:baseline;gap:14px;padding:14px 18px;border-bottom:1px solid var(--line)}
    h1{font-size:16px;margin:0}.count,.status{color:var(--dim)}.status{margin-left:auto;font-size:12px}
    main{padding:6px 0 20px}section{margin-top:14px}
    h2{font-size:11px;letter-spacing:.08em;color:var(--dim);margin:0;padding:4px 18px;font-weight:600}
    h2 .n{margin-left:6px;color:var(--fg)}
    .row{display:grid;grid-template-columns:14px 1fr auto;gap:10px;padding:7px 18px;border-top:1px solid var(--line);cursor:pointer}
    .row:hover,.row.open{background:var(--panel)}.row:focus{outline:1px solid var(--blue);outline-offset:-1px}
    .dot{width:9px;height:9px;border-radius:50%;margin-top:5px;background:var(--grey)}
    .green{background:var(--green)}.blue{background:var(--blue)}.red{background:var(--red)}.amber{background:var(--amber)}
    .grey{background:var(--grey)}.teal{background:var(--teal)}.purple{background:var(--purple)}
    .need{color:var(--amber);font-weight:600}.line{display:flex;gap:10px;min-width:0}
    .agent{font-family:ui-monospace,SFMono-Regular,Menlo,Consolas,monospace;color:var(--dim);white-space:nowrap}
    .topic{overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
    .prog{display:flex;align-items:center;gap:8px;margin-top:4px}
    .bar{display:flex;height:4px;width:160px;background:var(--line);border-radius:2px;overflow:hidden}
    .bar.big{width:100%;height:6px}.bar span{height:100%}.leaf{color:var(--dim);font-size:11px}
    .right{text-align:right;white-space:nowrap;font-size:12px}.right a{color:var(--fg);text-decoration:none;
    font-family:ui-monospace,SFMono-Regular,Menlo,Consolas,monospace}.right a:hover{text-decoration:underline}
    .prstate,.when{color:var(--dim)}.when.on{color:var(--blue)}
    .detail{display:grid;grid-template-columns:1fr 1fr;gap:24px;padding:10px 18px 16px 42px;background:var(--panel);
    border-top:1px dashed var(--line)}
    h3{font-size:11px;letter-spacing:.08em;color:var(--dim);margin:10px 0 6px;font-weight:600}
    ul{list-style:none;margin:0;padding:0}ul ul{padding-left:18px}li{margin:2px 0}
    .mark{display:inline-block;width:16px;color:var(--dim)}.mark.done{color:var(--green)}.mark.doing{color:var(--blue)}
    .mark.failed{color:var(--red)}.meta{color:var(--dim);font-size:12px}
    .tl li{display:grid;grid-template-columns:10px 44px 1fr;gap:6px;align-items:start}
    .tl .dot{width:7px;height:7px;margin-top:6px}.tl time{color:var(--dim);font-size:12px}
    button{background:none;border:1px solid var(--line);color:var(--dim);border-radius:4px;padding:2px 8px;font:inherit;cursor:pointer}
    dl{display:grid;grid-template-columns:90px 1fr;gap:3px 10px;margin:0}dt{color:var(--dim)}dd{margin:0;word-break:break-word}
    footer{padding:10px 18px;color:var(--red);font-size:12px}.empty{padding:6px 18px;color:var(--dim)}
    @media (max-width:760px){.detail{grid-template-columns:1fr;padding-left:18px}.bar{width:100px}}
  CSS

  # Builds every node with createElement + textContent; never innerHTML.
  JS = <<~'JS'
    (function () {
      "use strict";
      var POLL_MS = __POLL_MS__;
      var embedded = JSON.parse(document.getElementById("board-data").textContent);
      var opened = {}, longTimeline = {}, showAllIdle = false, last = null, receivedAt = 0;
      var MARKS = { done: "\u2713", doing: "\u25d0", todo: "\u25cb", failed: "\u2715" };
      var PR = /^https:\/\/github\.com\/[A-Za-z0-9-]+\/[A-Za-z0-9._-]+\/pull\/[0-9]+$/;
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
      function nowMs() {
        var base = Date.parse(last && last.generated_at);
        return isNaN(base) ? Date.now() : base + (embedded ? 0 : Date.now() - receivedAt);
      }
      function ago(iso) {
        var t = Date.parse(iso);
        if (isNaN(t)) return "";
        var s = Math.max(0, Math.round((nowMs() - t) / 1000));
        if (s < 60) return s + "s";
        if (s < 3600) return Math.floor(s / 60) + "m";
        if (s < 86400) return Math.floor(s / 3600) + "h";
        return Math.floor(s / 86400) + "d";
      }
      function hhmm(iso) {
        var d = new Date(iso);
        if (isNaN(d.getTime())) return "";
        return ("0" + d.getHours()).slice(-2) + ":" + ("0" + d.getMinutes()).slice(-2);
      }
      function minutes(from, to) {
        var a = Date.parse(from), b = to ? Date.parse(to) : nowMs();
        if (isNaN(a) || isNaN(b)) return "";
        var m = Math.max(0, Math.round((b - a) / 60000));
        return m < 120 ? m + " min" : Math.round(m / 60) + " h";
      }
      function bar(p, big) {
        var node = el("div", big ? "bar big" : "bar");
        if (!p || !p.total) return node;
        [["done", "green"], ["doing", "blue"], ["failed", "red"], ["todo", "grey"]].forEach(function (pair) {
          if (!p[pair[0]]) return;
          var seg = el("span", pair[1]);
          seg.style.width = (100 * p[pair[0]] / p.total) + "%";
          node.appendChild(seg);
        });
        return node;
      }
      function prLink(pr) {
        var a = el("a", null, pr.label);
        if (PR.test(pr.url)) {
          a.href = pr.url;
          a.target = "_blank";
          a.rel = "noopener noreferrer";
        }
        a.addEventListener("click", function (e) { e.stopPropagation(); });
        return a;
      }
      function checklist(items) {
        var ul = el("ul", "check");
        items.forEach(function (item) {
          var li = add(el("li"), el("span", "mark " + item.state, MARKS[item.state] || "?"), el("span", null, item.text));
          if (item.mark) li.appendChild(el("span", "meta", " (" + item.mark + ")"));
          if (item.children && item.children.length) li.appendChild(checklist(item.children));
          ul.appendChild(li);
        });
        return ul;
      }
      function detail(row) {
        var box = el("div", "detail");
        var left = el("div"), right = el("div");
        var t = row.tasks, p = t.progress;
        add(left, el("h3", null, t.source === "checklist" ? "TASKS" : "TASKS (acceptance criteria)"), bar(p, true));
        var pct = p.total ? Math.round(100 * p.done / p.total) + "%" : "no items";
        add(left, el("div", "meta", pct + " \u00b7 " + p.done + "/" + p.total + (t.started_at ? " \u00b7 " + minutes(t.started_at, t.ended_at) : "")));
        if (t.note) left.appendChild(el("div", "meta", t.note));
        left.appendChild(checklist(t.items));
        left.appendChild(el("h3", null, "LAST REPORT"));
        if (row.last_report) {
          add(left, el("div", "meta", hhmm(row.last_report.at) + " \u00b7 " + ago(row.last_report.at) + " ago \u00b7 " + row.last_report.kind),
              el("p", null, row.last_report.text));
        } else {
          left.appendChild(el("div", "meta", "none yet"));
        }
        right.appendChild(el("h3", null, "TIMELINE"));
        var ul = el("ul", "tl"), limit = longTimeline[row.id] ? row.timeline.length : 8;
        row.timeline.slice(0, limit).forEach(function (entry) {
          var time = el("time", null, hhmm(entry.at));
          time.setAttribute("datetime", entry.at);
          ul.appendChild(add(el("li"), el("span", "dot " + entry.color), time, el("span", null, entry.text)));
        });
        right.appendChild(ul);
        if (row.timeline.length > limit) {
          var more = el("button", null, "Show " + (row.timeline.length - limit) + " more");
          more.addEventListener("click", function (e) { e.stopPropagation(); longTimeline[row.id] = true; render(last); });
          right.appendChild(more);
        }
        right.appendChild(el("h3", null, "FACTS"));
        var dl = el("dl");
        row.facts.forEach(function (f) {
          var value = f.value + (f.at ? " " + ago(f.at) + " ago (" + hhmm(f.at) + ")" : "");
          add(dl, el("dt", null, f.label), el("dd", null, value));
        });
        right.appendChild(dl);
        return add(box, left, right);
      }
      function rowNode(row) {
        var wrap = el("div");
        var line = el("div", "row" + (opened[row.id] ? " open" : ""));
        line.tabIndex = 0;
        line.setAttribute("role", "button");
        line.setAttribute("aria-expanded", opened[row.id] ? "true" : "false");
        var main = el("div");
        if (row.need) main.appendChild(el("div", "need", "you: " + row.need));
        add(main, add(el("div", "line"), el("span", "agent", row.agent), el("span", "topic", row.topic)));
        var p = row.tasks.progress;
        add(main, add(el("div", "prog"), bar(p, false), el("span", "leaf", p.done + "/" + p.total)));
        var right = el("div", "right");
        row.prs.forEach(function (pr) {
          add(right, add(el("div"), prLink(pr), pr.state ? el("span", "prstate", " " + pr.state) : null));
        });
        right.appendChild(el("div", row.working ? "when on" : "when", row.working ? "working" : ago(row.updated_at)));
        add(line, el("span", "dot " + row.color), main, right);
        function toggle() { opened[row.id] = !opened[row.id]; render(last); }
        line.addEventListener("click", toggle);
        line.addEventListener("keydown", function (e) { if (e.key === "Enter" || e.key === " ") { e.preventDefault(); toggle(); } });
        wrap.appendChild(line);
        if (opened[row.id]) wrap.appendChild(detail(row));
        return wrap;
      }
      function render(data) {
        if (!data) return;
        var s = data.sections, idle = s.idle.filter(function (r) { return showAllIdle || r.recent; });
        var hidden = s.idle.length - idle.length;
        var shown = s.needs_you.length + s.working.length + idle.length;
        document.getElementById("count").textContent = shown + " agents \u00b7 " + s.needs_you.length + " needs you";
        var board = document.getElementById("board");
        var parts = [["NEEDS YOU", s.needs_you], ["WORKING", s.working], ["IDLE", idle]];
        var nodes = parts.map(function (part) {
          var sec = el("section");
          sec.appendChild(add(el("h2", null, part[0]), el("span", "n", part[1].length)));
          if (!part[1].length) sec.appendChild(el("div", "empty", "none"));
          part[1].forEach(function (row) { sec.appendChild(rowNode(row)); });
          return sec;
        });
        if (hidden || showAllIdle) {
          var toggle = el("button", null, showAllIdle ? "Show only the last 24 hours" : "Show all idle (" + hidden + " older)");
          toggle.addEventListener("click", function () { showAllIdle = !showAllIdle; render(last); });
          nodes[2].appendChild(add(el("div", "empty"), toggle));
        }
        board.replaceChildren.apply(board, nodes);
        var errors = document.getElementById("errors");
        errors.replaceChildren();
        data.errors.forEach(function (e) { errors.appendChild(el("div", null, "unreadable " + e.task + ": " + e.reason)); });
      }
      function status(text) { document.getElementById("status").textContent = text; }
      function poll() {
        if (!token) {
          status("open the URL board.rb printed: it carries this run's access token (#t=...)");
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
            status("live \u00b7 refreshed " + hhmm(data.generated_at) + " \u00b7 every " + data.poll_seconds + " s" + (data.gh ? "" : " \u00b7 gh off"));
          })
          .catch(function (e) { status("refresh failed (" + e.message + "); retrying"); })
          .then(function () { setTimeout(poll, POLL_MS); });
      }
      if (embedded) {
        last = embedded;
        render(embedded);
        status("snapshot " + embedded.generated_at + " (not live)");
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
