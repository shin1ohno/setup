# 検証 — 全ファイルが分類済みか

`find` で列挙した `files/` 配下の全ファイル（合計 53 件）を、`01-classification-matrix.md` の判定と突合せした結果。

凡例:

- ✅ matrix に出現・判定済み
- ⚠️ matrix で間接的に扱われている（カテゴリ単位、例: hooks 一括）

| # | ファイル | matrix 判定 | カバー |
|---:|---|---|---|
| 1 | `CLAUDE.md` | Preference + Code-only 部分 | ✅ A 節 |
| 2 | `agents/claude-docs-researcher.md` | Code-only | ✅ D 節 |
| 3 | `agents/domain-researcher.md` | Skill 内に統合（research-domains） | ✅ D 節 |
| 4 | `agents/mitamae-validator.md` | Code-only | ✅ D 節 |
| 5 | `agents/researcher.md` | Skill 内に統合（research） | ✅ D 節 |
| 6 | `agents/service-health-monitor.md` | Code-only | ✅ D 節 |
| 7 | `agents/session-retrospective.md` | Skill 内に統合（retro） | ✅ D 節 |
| 8 | `docs/knowledge-persistence.md` | Preference + Skill | ✅ A 節 |
| 9 | `hooks/block-co-authored-by.rb` | Code-only | ✅ E 節 |
| 10 | `hooks/check-trailing-newline.rb` | Code-only | ✅ E 節 |
| 11 | `hooks/check-whitespace-lines.rb` | Code-only | ✅ E 節 |
| 12 | `hooks/post-compact-remind.rb` | Code-only | ✅ E 節 |
| 13 | `hooks/pre-commit-test.rb` | Code-only | ✅ E 節 |
| 14 | `rules/architecture.md` | Preference | ✅ C 節 |
| 15 | `rules/claude-code-plugins.md` | Code-only | ✅ C 節 |
| 16 | `rules/data-collection.md` | Preference | ✅ C 節 |
| 17 | `rules/debugging.md` | Preference + Skill 候補 | ✅ C 節 |
| 18 | `rules/editing.md` | Code-only | ✅ C 節 |
| 19 | `rules/frontend-dev.md` | Project memory | ✅ C 節 |
| 20 | `rules/git-commit.md` | Code-only | ✅ C 節 |
| 21 | `rules/infrastructure.md` | Project memory + Preference 部分 | ✅ C 節 |
| 22 | `rules/ios-build.md` | Project memory | ✅ C 節 |
| 23 | `rules/mcp-config.md` | Code-only | ✅ C 節 |
| 24 | `rules/mise-migration.md` | Project memory | ✅ C 節 |
| 25 | `rules/release-plz.md` | Project memory | ✅ C 節 |
| 26 | `rules/remote-trigger.md` | Code-only | ✅ C 節 |
| 27 | `rules/ruby.md` | Project memory | ✅ C 節 |
| 28 | `rules/rust.md` | Project memory | ✅ C 節 |
| 29 | `rules/shell.md` | Preference 部分 + Project memory | ✅ C 節 |
| 30 | `rules/sub-agents.md` | Preference + Skill 候補 | ✅ C 節 |
| 31 | `rules/weave-protocol.md` | Project memory | ✅ C 節 |
| 32 | `rules/writing.md` | Bundle（writing skill 内） | ✅ C 節 |
| 33 | `settings.json` | Code-only | ✅ F 節 |
| 34 | `skills/check-services/SKILL.md` | Code-only | ✅ B 節 |
| 35 | `skills/feature-parity/SKILL.md` | Skill | ✅ B 節 |
| 36 | `skills/ingest-batch/SKILL.md` | Code-only | ✅ B 節 |
| 37 | `skills/ingest-pdf.md` | Skill（要書き換え → ingest-to-cognee） | ✅ B 節 |
| 38 | `skills/interview/SKILL.md` | Skill | ✅ B 節 |
| 39 | `skills/load-test/SKILL.md` | Code-only | ✅ B 節 |
| 40 | `skills/research-domains/SKILL.md` | Skill（簡略化） | ✅ B 節 |
| 41 | `skills/research/SKILL.md` | Skill | ✅ B 節 |
| 42 | `skills/retro/SKILL.md` | Skill（要改訂） | ✅ B 節 |
| 43 | `skills/security-review/SKILL.md` | Skill | ✅ B 節 |
| 44 | `skills/setup-release-plz/SKILL.md` | Code-only | ✅ B 節 |
| 45 | `skills/verify-cognee/SKILL.md` | Skill（条件付き） | ✅ B 節 |
| 46 | `skills/verify-data-integrity/SKILL.md` | Code-only | ✅ B 節 |
| 47 | `skills/verify-mise-backend/SKILL.md` | Code-only | ✅ B 節 |
| 48 | `skills/verify/SKILL.md` | Code-only | ✅ B 節 |
| 49 | `skills/writing/SKILL.md` | Skill | ✅ B 節 |
| 50 | `skills/writing/personas/document-writer.md` | Bundle | ✅ B 節 |
| 51 | `skills/writing/personas/marginal-utility-editor.md` | Bundle | ✅ B 節 |
| 52 | `skills/writing/templates/dvq.md` | Bundle | ✅ B 節 |
| 53 | `skills/writing/templates/rfc.md` | Bundle | ✅ B 節 |

**未分類**: 0 件
**カバレッジ**: 53 / 53 = 100%

---

## 副次チェック — 生成済み deliverable の整合性

| 期待ファイル | 実在 |
|---|---|
| `cowork-migration/01-classification-matrix.md` | ✅ |
| `cowork-migration/02-user-preferences.md` | ✅ |
| `cowork-migration/03-skills/writing/SKILL.md` | ✅ |
| `cowork-migration/03-skills/writing/personas/document-writer.md` | ✅ |
| `cowork-migration/03-skills/writing/personas/marginal-utility-editor.md` | ✅ |
| `cowork-migration/03-skills/writing/templates/dvq.md` | ✅ |
| `cowork-migration/03-skills/writing/templates/rfc.md` | ✅ |
| `cowork-migration/03-skills/interview/SKILL.md` | ✅ |
| `cowork-migration/03-skills/research/SKILL.md` | ✅ |
| `cowork-migration/03-skills/retro/SKILL.md` | ✅ |
| `cowork-migration/03-skills/research-domains/SKILL.md` | ✅ |
| `cowork-migration/03-skills/feature-parity/SKILL.md` | ✅ |
| `cowork-migration/03-skills/security-review/SKILL.md` | ✅ |
| `cowork-migration/03-skills/verify-cognee/SKILL.md` | ✅ |
| `cowork-migration/03-skills/ingest-to-cognee/SKILL.md` | ✅ |
| `cowork-migration/04-migration-guide.md` | ✅ |
| `cowork-migration/05-verification-checklist.md` | ✅（this file） |

deliverable 数: 17 ファイル（matrix / preferences / migration guide / verification + skills 13 件）
