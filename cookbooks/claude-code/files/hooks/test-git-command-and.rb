# frozen_string_literal: true
require "minitest/autorun"
require "tmpdir"
require "fileutils"
require "json"
require "open3"
require "rbconfig"
require "shellwords"
require_relative "git-command"

class GitCommandAndTest < Minitest::Test
  def setup
    @temporary = Dir.mktmpdir("commit-and-")
    @root = File.realpath(@temporary)
    @fail = File.join(@root, "fail")
    @pass = File.join(@root, "pass")
    @missing = File.join(@root, "missing")
    @bin = File.join(@root, "bin")
    @log = File.join(@root, "git.log")
    @make_log = File.join(@root, "make.log")
    [@fail, @pass, @bin].each { |path| FileUtils.mkdir_p(path) }
    [@fail, @pass].each { |path| File.write(File.join(path, "Makefile"), "test:\n") }
    File.write(File.join(@fail, "fails"), "fixture")
    executable("git", <<~SH)
      #!/bin/sh
      [ "$1" = commit ] || exit 97
      pwd -P >> "$ORACLE_LOG"
    SH
    executable("make", <<~SH)
      #!/bin/sh
      printf '%s|%s\n' "$PWD" "$*" >> "$MAKE_LOG"
      [ "$1" = -n ] && exit 0
      if [ -f fails ]; then echo AND-CONTINUATION-FAILURE; exit 1; fi
      exit 0
    SH
  end

  def teardown
    FileUtils.remove_entry(@temporary)
  end

  def executable(name, text)
    path = File.join(@bin, name)
    File.write(path, text)
    File.chmod(0o755, path)
  end

  def env
    { "HOME" => @root, "PATH" => "#{@bin}:/usr/bin:/bin", "BASH_ENV" => nil,
      "ENV" => nil, "ORACLE_LOG" => @log, "MAKE_LOG" => @make_log }
  end

  def cd(path)
    "cd #{Shellwords.escape(path)}"
  end

  def oracle(source, cwd)
    FileUtils.rm_f(@log)
    _out, err, status = Open3.capture3(env, "/bin/bash", "--noprofile", "--norc", "-c", source,
                                     chdir: cwd, unsetenv_others: true)
    directories = File.exist?(@log) ? File.readlines(@log).map(&:strip) : []
    if ENV["SH1_86_ORACLE_RESULTS"]
      File.open(ENV["SH1_86_ORACLE_RESULTS"], "a") do |file|
        file.puts(JSON.generate("command" => source, "cwd" => cwd,
                               "actual_git_cwds" => directories, "exit" => status.exitstatus,
                               "stderr" => err, "git_is_only_fake_pwd_script" => true))
      end
    end
    directories
  end

  def hook(source, cwd, name = "pre-commit-test.rb")
    FileUtils.rm_f(@make_log)
    payload = JSON.generate("cwd" => cwd, "tool_input" => { "command" => source })
    Open3.capture3(env, RbConfig.ruby, File.join(__dir__, name), stdin_data: payload, chdir: cwd, unsetenv_others: true)
  end

  def assert_guard(source, cwd, actual, exit_code)
    result = GitCommand.parse(source, cwd: cwd)
    assert_equal actual, oracle(source, cwd), source
    refute result.fallback, source
    actual.each { |directory| assert_includes result.commits.map(&:dir), directory, source }
    out, err, status = hook(source, cwd)
    assert_equal "", out
    assert_equal exit_code, status.exitstatus, "#{source}\n#{err}"
    assert_includes err, "AND-CONTINUATION-FAILURE" if exit_code == 2
  end

  def test_failed_first_cd_keeps_origin_after_semicolon
    assert_guard("#{cd(@missing)} && true; git commit -m x", @fail, [@fail], 2)
  end

  def test_failed_first_cd_keeps_origin_after_newline
    assert_guard("#{cd(@missing)} && true\ngit commit -m x", @fail, [@fail], 2)
  end

  def test_nested_and_keeps_first_failure_origin
    assert_guard("#{cd(@missing)} && { true && true; }; git commit -m x", @fail, [@fail], 2)
  end

  def test_second_cd_failure_keeps_first_target
    assert_guard("#{cd(@fail)} && #{cd(@missing)} && true; git commit -m x", @pass, [@fail], 2)
  end

  def test_third_cd_failure_keeps_second_target
    assert_guard("#{cd(@pass)} && #{cd(@fail)} && #{cd(@missing)} && true; git commit -m x", @pass, [@fail], 2)
  end

  def test_successful_cd_uses_target_without_guarding_origin
    assert_guard("#{cd(@pass)} && true; git commit -m x", @fail, [@pass], 0)
    assert_guard("#{cd(@pass)} && git commit -m x", @fail, [@pass], 0)
  end

  def test_successful_first_or_target_does_not_guard_failing_fallback
    assert_guard("#{cd(@pass)} || #{cd(@fail)}; git commit -m x", @fail, [@pass], 0)
  end

  def test_failed_cd_does_not_reach_commit_on_and_rhs
    source = "#{cd(@missing)} && git commit -m x"
    assert_guard(source, @fail, [], 0)
    refute File.exist?(@make_log), "an unreachable commit must not test the origin"
  end

  def test_reachable_failure_with_clean_origin_allows
    assert_guard("#{cd(@missing)} && true; git commit -m x", @pass, [@pass], 0)
  end

  def test_distinct_repeated_commits_survive_path_deduplication
    source = "#{cd(@missing)} && true; git commit -m x; git commit -m x"
    assert_guard(source, @pass, [@pass, @pass], 0)
    assert_equal 2, GitCommand.parse(source, cwd: @pass).commits.count { |invocation| invocation.dir == @pass }
  end

  def test_known_false_does_not_reach_commit
    assert_guard("false && git commit -m x", @fail, [], 0)
    refute File.exist?(@make_log)
  end

  def test_eval_preserves_failed_and_cwd_for_parent_continuation
    source = "eval #{Shellwords.escape("#{cd(@missing)} && true")}; git commit -m x"
    assert_guard(source, @fail, [@fail], 2)
  end

  def test_eval_cwd_alternatives_keep_the_failure_of_its_own_branch
    sub = File.join(@pass, "sub")
    Dir.mkdir(sub)
    File.write(File.join(sub, "Makefile"), "test:\n")
    script = "if test -e #{Shellwords.escape(@missing)}; then #{cd(@pass)}; else #{cd(@fail)}; fi"
    source = "eval #{Shellwords.escape(script)}; cd sub && true; git commit -m x"
    assert_guard(source, @pass, [@fail], 2)
  end

  def test_unknown_command_invalidates_existing_directory_snapshot
    removable = File.join(@root, "removable")
    Dir.mkdir(removable)
    source = "rmdir #{Shellwords.escape(removable)}; #{cd(removable)} && true; git commit -m x"
    assert_guard(source, @fail, [@fail], 2)
  end

  def test_missing_component_before_dotdot_is_not_proven_successful
    source = "#{cd(File.join(@missing, '..', 'pass'))} && true; git commit -m x"
    assert_guard(source, @fail, [@fail], 2)
  end

  def test_quoted_data_is_not_a_commit_after_and_failure
    source = "#{cd(@missing)} && true; printf '%s' 'git commit Co-Authored-By'"
    assert_guard(source, @fail, [], 0)
    assert_empty GitCommand.parse(source, cwd: @fail).commits
    _out, err, status = hook(source, @fail, "block-co-authored-by.rb")
    assert_equal 0, status.exitstatus
    assert_equal "", err
  end

  def test_coauthor_block_and_clean_pair_after_and_failure
    ["Co-Authored-By: fixture", "Reviewed-by: fixture"].zip([2, 0]).each do |message, expected|
      source = "#{cd(@missing)} && true; git commit -m #{Shellwords.escape(message)}"
      _out, _err, status = hook(source, @fail, "block-co-authored-by.rb")
      assert_equal expected, status.exitstatus, source
    end
  end
end
