# frozen_string_literal: true
#
# End-of-apply gate visibility (hurdle-removal plan 2026-08, stream A).
#
# Included LAST by every entry recipe — via lxc_entry's tail for the LXC
# fleet + pve-host, and an explicit tail include in darwin.rb / linux.rb /
# pve/lxc-apm-server.rb (which opts out of lxc_entry). Being last means this
# file's compile phase runs after every require_external_auth gate has
# recorded its outcome via record_gate_event ($gate_events, see
# cookbooks/functions/default.rb), and the resources declared here converge
# at the very end of the apply.
#
# Outputs:
#   1. stdout summary — the last converge output: which gates were skipped
#      and why. tool_missing adds a RE-RUN REQUIRED banner: gates check at
#      COMPILE time while installers (awscli) converge later, so on a fresh
#      machine the FIRST apply always skips every SSM-gated cookbook.
#   2. /var/lib/node_exporter/textfile/mitamae-gates.prom — only where the
#      textfile dir exists and is writable (fleet hosts applying as root;
#      darwin/bare user applies skip via only_if). Drives the
#      MitamaeGateNeedsAttention Prometheus alert. Written even when
#      attention == 0 so a recovered host clears the alert.
#   3. sentinel <setup-root>/.gate-rerun-required — present only when a
#      tool_missing skip happened this run; bin/doctor reports it.

events = $gate_events || []
attention_reasons = [:tool_missing, :auth_unavailable, :user_skip]
attention = events.select { |e| attention_reasons.include?(e[:reason]) }
rerun_required = events.any? { |e| e[:reason] == :tool_missing }

# Report lines and metric labels are compile-time-built strings embedded into
# execute commands. Strip everything outside a conservative charset so shell
# quoting / history expansion can never bite (~/.claude/rules/shell.md).
gate_report_sanitize_line = ->(s) { s.to_s.gsub(%r{[^A-Za-z0-9 _.,:()/=+*{}\[\]-]}, "") }
gate_report_sanitize_label = lambda do |s|
  s.to_s.downcase.gsub(/[^a-z0-9]+/, "_").sub(/\A_+/, "").sub(/_+\z/, "")[0, 60]
end

report_lines = ["=== mitamae gate report: #{events.size} gates, #{attention.size} need attention ==="]
attention.each do |e|
  fix = e[:reason] == :tool_missing ? "re-run mitamae (installer converged this run)" : "fix auth (bin/doctor), then re-run"
  report_lines << "SKIPPED #{gate_report_sanitize_line.call(e[:tool])} [#{e[:reason]}] -> #{fix}"
end
if rerun_required
  report_lines << ">>> RE-RUN REQUIRED: a prerequisite tool was installed this run - re-run the same mitamae command <<<"
end

execute "mitamae gate report" do
  command report_lines.map { |l| "echo '#{l}'" }.join(" && ")
end

# --- node-exporter textfile metric (fleet observability) ---------------------
# Literal path rather than node-exporter's NODE_EXPORTER_TEXTFILE_DIR constant:
# darwin/bare-metal applies never include the node-exporter cookbook, so the
# constant is undefined there while this cookbook still compiles.
gate_report_textfile_dir = "/var/lib/node_exporter/textfile"
prom_lines = [
  "# HELP mitamae_gate_attention_total gates skipped this apply that need operator attention",
  "# TYPE mitamae_gate_attention_total gauge",
  "mitamae_gate_attention_total #{attention.size}",
  "# HELP mitamae_gate_events_total require_external_auth gates evaluated this apply",
  "# TYPE mitamae_gate_events_total gauge",
  "mitamae_gate_events_total #{events.size}",
]
attention.map { |e| [gate_report_sanitize_label.call(e[:tool]), e[:reason]] }.uniq.each do |label, reason|
  prom_lines << "mitamae_gate_skip{gate=\"#{label}\",reason=\"#{reason}\"} 1"
end

prom_tmp = "#{gate_report_textfile_dir}/mitamae-gates.prom.tmp"
prom_out = "#{gate_report_textfile_dir}/mitamae-gates.prom"
execute "write mitamae-gates.prom" do
  command "printf '%s\\n' " + prom_lines.map { |l| "'#{l}'" }.join(" ") +
          " > #{prom_tmp}" \
          " && printf 'mitamae_gate_report_timestamp_seconds %s\\n' \"$(date +%s)\" >> #{prom_tmp}" \
          " && mv #{prom_tmp} #{prom_out}"
  only_if "test -w #{gate_report_textfile_dir}"
end

# --- fresh-machine two-apply sentinel (read by bin/doctor) -------------------
gate_rerun_sentinel = File.join(node[:setup][:root], ".gate-rerun-required")
if rerun_required
  execute "write gate-rerun sentinel" do
    command "printf 'tool_missing gates were skipped this apply; re-run mitamae\\n' > #{gate_rerun_sentinel}"
  end
else
  execute "clear gate-rerun sentinel" do
    command "rm -f #{gate_rerun_sentinel}"
    only_if "test -f #{gate_rerun_sentinel}"
  end
end
