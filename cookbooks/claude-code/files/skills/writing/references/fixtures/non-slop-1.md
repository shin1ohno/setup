<!-- guard: 中立な技術リファレンス。英語識別子・コード片を含む日本語散文。意見や一人称を注入してはならない（blader genre gate）。実質無変更で通ること。-->

`writing` skill は SKILL.md から `document-writer` と `marginal-utility-editor` の 2 ペルソナを Read し、Plan・Write・Edit の 3 ステップを Agent ツールで順に実行する。各ステップは独立したサブエージェントで、`node[:setup][:home]/.claude/skills/writing/` 配下のファイルを参照する。Edit ステップは `marginal-utility-editor.md` の `### 4. Format Check` までを適用する。
