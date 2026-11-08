#!/usr/bin/env ruby
# frozen_string_literal: true

# Stop hook for Chief of Staff workers: tell the controller, once, that this
# attempt's envelope exists.
#
# Registered for every Claude session and inert unless the controller launched
# this one with all of COS_WORKER_TASK_ID, COS_WORKER_ATTEMPT,
# COS_CONTROLLER_PANE and COS_CONTROLLER_SESSION. Stop fires at the end of every
# turn, so nothing is sent until the attempt's envelope file exists.
#
# The message is built only from the validated task id and attempt plus a
# constant state word. Text typed into the controller pane arrives there as if
# the user wrote it, so nothing from the worker, the envelope or the transcript
# may reach it: the envelope is only ever lstat'ed, never read.
#
# One attempt per task attempt: the marker is claimed with O_EXCL before sending
# and is never released. A send refused because the controller sits at a dialog
# is not retried here; the controller's background `herdr agent wait` wakes on
# the same transition. The marker records the exit status for later diagnosis.
#
# `herdr agent prompt` refuses a target waiting at a dialog before sending any
# input; `pane send-text` has no such guard and could answer the dialog.
#
# Never fails the worker's turn: any problem -> no output, exit 0.

TASK_ID_RE = /\A[0-9a-f]{16}\z/
ATTEMPT_RE = /\A[1-9][0-9]{0,2}\z/
# Herdr numbers panes past 9 with letters: w1:p9, w1:pA, w1:pB.
PANE_RE = /\Aw[0-9A-Za-z]+:p[0-9A-Za-z]+\z/
SESSION_RE = /\A[A-Za-z0-9][A-Za-z0-9_-]{0,63}\z/

STATE_WORD = "envelope-ready"
SEND_TIMEOUT_SECONDS = 5.0

def run_herdr(argv)
  pid = spawn_herdr(argv)
  return "not-found" if pid.nil?

  deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + SEND_TIMEOUT_SECONDS
  loop do
    _, status = Process.wait2(pid, Process::WNOHANG)
    return "exit=#{status.exitstatus.inspect}" if status
    break if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline

    sleep 0.05
  end

  Process.kill("KILL", pid)
  Process.wait(pid)
  "timeout"
end

# A worker started through hc has a PATH without ~/.local/bin.
def spawn_herdr(argv)
  ["herdr", File.expand_path("~/.local/bin/herdr")].each do |program|
    begin
      return Process.spawn(program, *argv, in: File::NULL, out: File::NULL, err: File::NULL)
    rescue Errno::ENOENT, Errno::EACCES
      next
    end
  end
  nil
end

def envelope_ready?(path)
  stat = File.lstat(path)
  stat.file? && stat.size.positive?
rescue SystemCallError
  false
end

def claim(marker)
  File.open(marker, File::WRONLY | File::CREAT | File::EXCL, 0o600)
rescue SystemCallError
  nil
end

def main
  task, attempt, pane, session = ENV.values_at(
    "COS_WORKER_TASK_ID", "COS_WORKER_ATTEMPT", "COS_CONTROLLER_PANE", "COS_CONTROLLER_SESSION"
  )
  return unless TASK_ID_RE.match?(task.to_s) && ATTEMPT_RE.match?(attempt.to_s)
  return unless PANE_RE.match?(pane.to_s) && SESSION_RE.match?(session.to_s)

  require "json"
  payload = JSON.parse($stdin.read)
  return unless payload.is_a?(Hash) && payload["hook_event_name"] == "Stop"

  root = ENV["COS_STATE_DIR"].to_s
  root = File.expand_path("~/.local/state/chief-of-staff") if root.empty?
  return unless root.start_with?("/")

  task_dir = File.join(root, task)
  return unless envelope_ready?(File.join(task_dir, "envelope-#{attempt}.json"))

  marker = claim(File.join(task_dir, "stop-hook-notified-#{attempt}"))
  return if marker.nil?

  message = "[task #{task} attempt #{attempt}] #{STATE_WORD}"
  outcome = run_herdr(["--session", session, "agent", "prompt", pane, message])
  marker.puts(outcome)
  marker.close
end

begin
  main
rescue StandardError
  nil
end
exit 0
