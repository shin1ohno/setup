#!/usr/bin/env ruby
# frozen_string_literal: true

# PostToolUse hook (Edit|Write): fixes the edited file in place, in order —
# rustfmt for .rs, terraform fmt for .tf/.tfvars, whitespace-only lines emptied,
# trailing newline added — and tells Claude what changed. One hook does all
# three so no two hooks rewrite the same file concurrently. It never blocks the
# edit: a missing tool, a file outside a crate or a formatter error exits 0.

require "json"
require "open3"

SKIP_EXTENSIONS = %w[.png .jpg .jpeg .gif .ico .webp .woff .woff2 .ttf .otf .pdf .zip .gz .tgz .tar .bin .lock].freeze
MAX_BYTES = 5 * 1024 * 1024

def find_tool(name)
  dirs = ENV.fetch("PATH", "").split(File::PATH_SEPARATOR)
  dirs += [File.join(Dir.home, ".cargo", "bin"), "/opt/homebrew/bin", "/usr/local/bin"]
  dirs.each do |dir|
    candidate = File.join(dir, name)
    return candidate if File.file?(candidate) && File.executable?(candidate)
  end
  nil
end

def rust_edition(cargo, path)
  out, status = Open3.capture2(cargo, "locate-project", "--message-format", "plain", chdir: File.dirname(path))
  return nil unless status.success?

  manifest = out.strip
  meta, status = Open3.capture2(cargo, "metadata", "--no-deps", "--format-version", "1",
                                "--manifest-path", manifest, chdir: File.dirname(manifest))
  return nil unless status.success?

  package = JSON.parse(meta).fetch("packages", []).find { |p| p["manifest_path"] == manifest }
  package && package["edition"]
end

# Returns the formatter name when it ran cleanly, nil when skipped.
def run_formatter(path)
  case File.extname(path)
  when ".rs"
    cargo = find_tool("cargo")
    rustfmt = find_tool("rustfmt")
    return nil unless cargo && rustfmt

    edition = rust_edition(cargo, path)
    return nil unless edition

    _out, status = Open3.capture2e(rustfmt, "--edition", edition, path, chdir: File.dirname(path))
    return "rustfmt" if status.success?

    warn "format-on-edit: rustfmt failed on #{path}"
    nil
  when ".tf", ".tfvars"
    terraform = find_tool("terraform")
    return nil unless terraform

    _out, status = Open3.capture2e(terraform, "fmt", "-no-color", path, chdir: File.dirname(path))
    return "terraform fmt" if status.success?

    warn "format-on-edit: terraform fmt failed on #{path}"
    nil
  end
end

# Empties whitespace-only lines (keeping a CRLF line's \r) and adds a missing
# final newline. Works on bytes so non-UTF-8 text survives.
def tidy(data)
  crlf = data.include?("\r\n")
  emptied = 0
  lines = data.split("\n", -1).map do |line|
    cr = line.end_with?("\r") ? "\r" : ""
    body = cr.empty? ? line : line[0...-1]
    if !body.empty? && body.match?(/\A[ \t\f\v]+\z/n)
      emptied += 1
      cr
    else
      line
    end
  end
  out = lines.join("\n")
  added_newline = !out.empty? && !out.end_with?("\n")
  out << (crlf ? "\r\n" : "\n") if added_newline
  [out, emptied, added_newline]
end

begin
  payload = JSON.parse($stdin.read)
  path = payload.dig("tool_input", "file_path").to_s
  exit 0 if path.empty? || !File.file?(path)
  exit 0 if SKIP_EXTENSIONS.include?(File.extname(path).downcase)
  exit 0 if File.size(path) > MAX_BYTES

  before = File.binread(path)
  exit 0 if before.empty? || before.byteslice(0, 8192).include?("\0")

  formatter = run_formatter(path)
  formatted = File.binread(path)
  tidied, emptied, added_newline = tidy(formatted.dup)
  File.binwrite(path, tidied) if tidied != formatted

  notes = []
  notes << "formatted with #{formatter}" if formatter && formatted != before
  notes << "emptied #{emptied} whitespace-only line(s)" if emptied.positive?
  notes << "added the final newline" if added_newline
  exit 0 if notes.empty?

  puts JSON.generate(
    "hookSpecificOutput" => {
      "hookEventName" => "PostToolUse",
      "additionalContext" => "format-on-edit: #{path} — #{notes.join(', ')}. Re-read the file before editing it again."
    }
  )
rescue StandardError => e
  # Fail open: a broken fixer must never block or fail the edit it follows.
  warn "format-on-edit: #{e.class}"
  exit 0
end
