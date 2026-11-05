# frozen_string_literal: true
require "minitest/autorun"
require_relative "git-command"

class GitCommandFlowTest < Minitest::Test
  def commits(source)
    result = GitCommand.parse(source, cwd: "/fixture/work", home: "/fixture/home")
    refute result.fallback, source
    refute result.commits.any?(&:fallback), source
    result.commits
  end

  def directories(source)
    commits(source).map(&:dir).uniq.sort_by(&:to_s)
  end

  def test_cd_alternatives_keep_both_successes_and_the_failure_origin
    assert_equal %w[/a /b /fixture/work], directories("cd /a || cd /b; git commit")
  end

  def test_relative_fallback_cd_resolves_from_failed_cd_origin
    assert_equal %w[/a /fixture/work/sub /fixture/work].sort,
                 directories("cd /a || cd sub; git commit")
  end

  def test_if_elif_else_keep_every_reachable_directory
    assert_equal %w[/a /b /c], directories("if probe; then cd /a; elif other; then cd /b; else cd /c; fi; git commit")
  end

  def test_cd_in_condition_changes_only_its_success_branch
    assert_equal %w[/a /fixture/work], directories("if cd /a; then git commit; else git commit; fi")
  end

  def test_known_status_does_not_visit_unreachable_branch
    assert_equal ["/a"], directories("if true; then cd /a; else cd /b; fi; git commit")
    assert_equal ["/b"], directories("if false; then cd /a; else cd /b; fi; git commit")
    assert_equal [], directories("false && git commit || printf clean")
  end

  def test_branch_variables_reach_their_own_continuation
    assert_equal %w[/a /b], directories('if probe; then R=/a; else R=/b; fi; git -C "$R" commit')
  end

  def test_nested_shell_and_subshell_do_not_leak_cwd
    assert_equal %w[/a /b /fixture/work], directories("(if probe; then cd /a; else cd /b; fi; git commit); git commit")
    assert_equal %w[/a /b /fixture/work], directories("sh -c 'if probe; then cd /a; else cd /b; fi; git commit'; git commit")
  end

  def test_sudo_value_consumption_and_command_boundary
    %w[-iu -Hu -Eu].each do |cluster|
      assert_equal ["/a"], directories("sudo #{cluster} fixture sh -c 'git -C /a commit'")
      assert_equal [], commits("sudo #{cluster} fixture printf '%s' 'git commit'")
    end
    assert_equal ["/a"], directories("sudo -Huuser -D/a git commit")
    assert_equal ["/a"], directories("sudo --user=fixture --chdir=/a -- git commit")
    assert_equal [], commits("sudo -l -u fixture git commit -m forbidden")
    assert_equal [], commits("sudo --edit git commit")
    assert_equal [], commits("sudo -p 'git commit' printf clean")
  end

  def test_wrappers_preserve_values_and_do_not_scan_data
    assert_equal [], commits("su -c 'printf \"git commit\"' fixture")
    assert_equal ["/a"], directories("xargs -i sh -c 'git -C /a commit'")
    assert_equal ["/a"], directories("xargs --replace sh -c 'git -C /a commit'")
    assert_equal [], commits("printf '%s' if else 'git commit'")
    assert_equal [], commits("xargs -I sh printf '%s' 'git commit'")
    assert_equal [], commits("flock -w sh /lock printf '%s' 'git commit'")
    assert_equal [], commits("find . -name 'git commit' -print")
    assert_equal [nil], directories("find . -execdir sh -c 'git commit' sh {} +")
    assert_equal ["/a", "/b"], directories("find . -exec sh -c 'git -C /a commit' sh {} \\; -exec git -C /b commit \\;")
  end

  def test_or_brace_group_does_not_run_on_the_success_path
    assert_equal %w[/a /b], directories("cd /a || { cd /b; git commit; }; git commit")
    assert_equal ["/fixture/work"], directories("true || { cd /bad; git commit; }; git commit")
  end

  def test_keyword_arguments_and_continued_or_list
    assert_equal %w[/a /b], directories("if test then = then; then cd /a; else cd /b; fi; git commit")
    assert_equal %w[/a /b /fixture/work], directories("cd /a ||\ncd /b; git commit")
  end

  def test_eval_retains_cwd_alternatives_for_later_commands
    assert_equal %w[/a /b], directories("eval 'if probe; then cd /a; else cd /b; fi'; git commit")
    assert_equal ["/fixed"], directories("eval 'if probe; then cd /a; else cd /b; fi'; R=/fixed; git -C \"$R\" commit")
  end

  def test_cwd_cross_product_and_nested_evaluation_are_bounded
    source = (["eval 'if probe; then cd x; else cd y; fi'"] * 7).join("; ") + "; git commit"
    assert_operator commits(source).size, :<=, GitCommand::FlowPaths::MAX_PATHS
    source = "if p; then cd /a; else cd /b; fi"
    3.times { source = "eval " + source.inspect }
    result = GitCommand.parse(source + "; git -C /explicit commit", cwd: "/fixture/work")
    assert_includes result.commits.map(&:dir), "/explicit"
  end

  def test_unlisted_wrapper_shell_entry_points_and_data_counterparts
    assert_equal ["/a"], directories("custom-runner -- bash -c 'git -C /a commit'")
    assert_equal ["/a"], directories("setsid sh -c 'git -C /a commit'")
    assert_equal [], commits("custom-runner -- printf '%s' 'git commit'")
    assert_equal [], commits("custom-runner --label 'bash -c git commit'")
    assert_equal [], commits("cat sh <<EOF\ngit commit\nEOF")
  end

  def test_shell_prefix_environment_is_scoped_to_the_child
    assert_equal ["/a"], directories('env R=/a flock /lock sh -c \'git -C "$R" commit\'')
    assert_equal ["/a", "/b"], directories('R=/b; env R=/a sh -c \'git -C "$R" commit\'; git -C "$R" commit')
  end

  def test_path_budget_is_bounded
    source = (1..8).map { |n| "if p; then cd /a#{n}; else cd /b#{n}; fi" }.join("; ") + "; git -C /explicit commit"
    result = GitCommand.parse(source, cwd: "/fixture/work")
    assert_operator result.commits.size, :<=, GitCommand::FlowPaths::MAX_PATHS
    assert_equal ["/explicit"], result.commits.map(&:dir).uniq
  end
end

# Keep the AND continuation regressions in their own topic file.
require_relative "test-git-command-and"

require_relative "test-git-command-cd-proof"
