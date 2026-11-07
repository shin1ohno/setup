#!/usr/bin/env ruby
# frozen_string_literal: true

# Unapplied canary only. This instructional preflight never approves a tool.
require "json"
require "digest"
require "fileutils"
require "optparse"
require_relative "git-command"

options = {}
OptionParser.new do |parser|
  parser.on("--document PATH") { |value| options[:document] = value }
  parser.on("--state-directory PATH") { |value| options[:state] = value }
end.parse!

begin
  data = JSON.parse($stdin.read(65_537))
  exit 0 unless data["tool_name"] == "Bash"
  command = data.dig("tool_input", "command").to_s
  # Unknown aliases/wrappers remain subject to the always-loaded read instruction.
  mutating = %w[add branch checkout cherry-pick clean commit merge pull push rebase reset restore revert rm stash switch tag worktree]
  invocations = GitCommand.parse(command, cwd: data["cwd"] || Dir.pwd).invocations
  git = invocations.any? { |invocation| mutating.include?(invocation.subcommand) }
  # Broad matching is intentional: false positives only request instruction review.
  github = command.match?(/\bgh\b.*\b(?:pr|release)\b.*\b(?:create|merge|edit|close|delete)\b/m)
  exit 0 unless git || github

  session = data["session_id"]
  raise "missing session identity" unless session.is_a?(String) && !session.empty? && session.bytesize <= 256
  document = options.fetch(:document)
  state = options.fetch(:state)
  raise "absolute paths required" unless document.start_with?("/") && state.start_with?("/")
  body = File.open(document, "rb") { |file| file.read(32_769) }
  raise "invalid procedure document" if body.empty? || body.bytesize > 32_768 || !body.force_encoding("UTF-8").valid_encoding?
  FileUtils.mkdir_p(state, mode: 0o700)
  raise "unsafe state directory" if File.symlink?(state) || File.stat(state).uid != Process.uid || (File.stat(state).mode & 0o077) != 0
  marker = File.join(state, Digest::SHA256.hexdigest(session + "\0" + body))
  begin
    File.open(marker, File::WRONLY | File::CREAT | File::EXCL, 0o600) { |file| file.write("instruction response emitted; consumption unproven\n") }
  rescue Errno::EEXIST
    exit 0
  end
  # Deny-once emits the procedure before any mutation. The marker proves only emission.
  warn "GIT_PROCEDURE_PREFLIGHT: Read these procedures, then retry through all existing permission checks. This is not a permission rejection or approval.\n\n#{body}"
  exit 2
rescue StandardError => error
  warn "GIT_PROCEDURE_PREFLIGHT_ERROR: #{error.message}. Read the configured Git procedures before retrying."
  exit 2
end
