# frozen_string_literal: true
require_relative "test-git-command-and"

class GitCommandAndTest
  def assert_bash_flag(flag)
    source = "cd #{flag} #{Shellwords.escape(@pass)} && true; git commit -m x"
    actual = oracle(source, @fail)
    assert_includes [[@fail], [@pass]], actual
    assert_guard(source, @fail, actual, actual == [@fail] ? 2 : 0)
  end

  def test_cd_e_follows_actual_bash_version
    assert_bash_flag("-e")
  end

  def test_cd_at_follows_actual_bash_version
    assert_bash_flag("-@")
  end

  def test_cd_l_and_p_are_clean_positive_controls
    %w[-L -P].each { |flag| assert_bash_flag(flag) }
  end

  def test_cd_option_terminator_and_unknown_option
    assert_guard("cd -- #{Shellwords.escape(@pass)} && true; git commit -m x", @fail, [@pass], 0)
    assert_guard("cd --bogus #{Shellwords.escape(@pass)} && true; git commit -m x", @fail, [@fail], 2)
  end

  def test_cd_extra_operand_matches_actual_bash_instead_of_assuming_failure
    source = "#{cd(@pass)} extra && true; git commit -m x"
    actual = oracle(source, @fail)
    assert_includes [[@fail], [@pass]], actual
    assert_guard(source, @fail, actual, actual == [@fail] ? 2 : 0)
  end

  def test_cd_redirection_failure_retains_origin
    source = "#{cd(@pass)} > #{Shellwords.escape(File.join(@missing, 'out'))} && true; git commit -m x"
    assert_guard(source, @fail, [@fail], 2)
  end

  def test_quoted_data_after_redirection_failure_is_not_a_commit
    source = "#{cd(@pass)} > #{Shellwords.escape(File.join(@missing, 'out'))} && true; printf '%s' 'git commit Co-Authored-By'"
    assert_guard(source, @fail, [], 0)
    _out, err, status = hook(source, @fail, "block-co-authored-by.rb")
    assert_equal 0, status.exitstatus
    assert_equal "", err
  end

  def test_external_wrapper_cannot_change_its_parent_cwd
    assert_guard("env cd #{Shellwords.escape(@pass)} && true; git commit -m x", @fail, [@fail], 2)
  end

  def test_permission_result_matches_actual_bash_and_identity
    File.chmod(0, @pass)
    source = "#{cd(@pass)} && true; git commit -m x"
    actual = oracle(source, @fail)
    assert_guard(source, @fail, actual, actual == [@fail] ? 2 : 0)
  ensure
    File.chmod(0o700, @pass)
  end

  def test_timed_out_probe_retains_failure_and_reaps_only_its_child
    original_spawn = Process.method(:spawn)
    child = nil
    replacement = lambda do |*_, **_options|
      child = original_spawn.call("/bin/sleep", "5", in: File::NULL, out: File::NULL, err: File::NULL)
    end
    evaluator = GitCommand::Evaluator.new(@root)
    refute evaluator.send(:probe_bash_cd, [@pass], spawn: replacement)
    assert_raises(Errno::ECHILD) { Process.waitpid(child, Process::WNOHANG) }
  end

  def test_cdpath_destination_is_a_candidate_not_just_the_origin
    destination = File.join(@root, "lookup", "target")
    FileUtils.mkdir_p(destination)
    File.write(File.join(destination, "Makefile"), "test:\n")
    File.write(File.join(destination, "fails"), "fixture")
    source = "export CDPATH=#{Shellwords.escape(File.dirname(destination))}; cd target && true; git commit -m x"
    assert_guard(source, @pass, [destination], 2)
  end
end
