# self-heal Phase 3（infra 自動 resize）— adversarial security review + hardened 案B

**Date**: 2026-07-05
**Issue**: shin1ohno/setup#642 Phase 3
**Status**: 案B-as-specced = **blockers: 3**（実装不可）。owner 決定（2026-07-05）= **hardening 込みで案B 実装**。
本 doc の「hardened 案B」が blockers を 0 にする設計。**この設計に沿って初めて PR-3b の実装コードを書く。**

`docs/self-heal-autonomy-improvement-plan.md` §4 を本 doc で上書きする。

## 事実訂正（初版 plan の誤り）

- resize 値は `home-monitor/pve-lxcs.tf` の `lxc_specs` **ではない**。`local.lxc_specs` は `contracts.tf` が
  `jsondecode(file("contracts/devices.json"))` を `kind=="lxc"` で filter して**導出**する。resize =
  `home-monitor/contracts/devices.json` を編集して CodeCommit `home-monitor` main に commit。
- home-monitor は **CodeCommit で PR/CI ゲートが無い**（setup cookbook 経路と違い review artifact が残らない）。
  → infra 経路の唯一の防御は self-inspect した plan JSON = cookbook 経路より弱い。
- `lifecycle.ignore_changes = [initialization.user_account, operating_system, mount_point]`。`memory`/`cpu` は
  managed なので resize は in-place `update`（replace しない）= TF 層では可逆。だが cgroup live-apply のため
  **縮小は破壊的**（下記 blocker 1）。

## Blocker → 緩和（hardened 案B が blockers:0 に到達する対応表）

| # | blocker（案B-as-specced） | hardened 案B の緩和 |
|---|---|---|
| **1a** | 値の **floor が無い** → gate を通る memory/cores **縮小**が live 使用量を下回り対象サービスを **OOM-kill**（LXC `dedicated` は hard cgroup ceiling） | allowlist に `min_memory_mb`/`min_cores` を必須化 + **increase-only**（自律経路では減少禁止。減少は needs-human）。wrapper が delta>0 を強制 |
| **2a** | admin（`sh1admn`=AdministratorAccess）+ 全域 PVE token 上の **prompt-level gate は境界でない**。bypassPermissions + 注入/バグで AWS 全権 + 全 CT 破壊が射程 | (i) 専用 **non-admin AWS sub-profile `pve-resize`**（下記 §B）に切替。(v) **apply を非LLM の deterministic wrapper に移す** — opus は `{ct, target_mb, target_cores}` を提案するだけ、shell wrapper が allowlist∩caps∩floor を強制し plan を回して JSON を self-check して apply。LLM が apply verb を直接持たない |
| **2c** | PVE `root@pam!terraform` トークンが **データセンター全域** → AWS を絞っても cosmetic | (ii) **スコープ化 PVE token/role**（下記 §B）: `VM.Config.Memory`/`VM.Config.CPU`/`VM.Audit` のみ・**per-CT ACL**（allowlist の CT ID だけ）・`VM.Allocate`/`Disk`/`Network`/`Console`/`Datastore`/`SDN` を除外 → create/destroy 不能 |
| **1b** | gate が array-action（replace=`["delete","create"]`）と「target 以外は全て no-op/read」を厳密に見ないと、bundle された他変更を apply | wrapper の plan-JSON check を **fail-closed**: `.resource_changes[]` を全走査し、target CT が `["update"]` かつ他が全て `["no-op"]`/`["read"]`、変更フィールドが memory/cpu のみ、`0 to destroy`。1 つでも外れたら abort→needs-human。`terraform apply <planfile>` は保存 plan を verbatim 適用するので、同じ planfile を全走査すれば健全 |
| **3a** | 公開リポ + 未サニタイズ issue body（`dedup_key` 生埋め込み、`proc` 名が fleet code-exec で攻撃者設定可）→ admin bypassPermissions への **prompt injection** | 2a の非LLM wrapper が最大の緩和（LLM が値を提案しても wrapper が allowlist/floor/ceiling/CT-map で拘束）。加えて target CT + 値は **allowlist ∩ `contracts/devices.json` の検証済み map** から deterministic に算出、issue 本文の prose から選ばない（3c） |

補助（risk、hardened 設計で対応）:

- **1c/5c** 他 CT の out-of-band drift が同 apply に載る/戻す → PVE を**別 state に分離**（§B）し、resize 経路は
  IAM/RDS/TLS を含む主 state を読まない。target-CT-only check で fail-closed（頻繁 abort は許容、緩めない）。
- **3d** resize-to-max 連打で PVE host RAM oversubscribe → **per-CT + fleet-wide の resize budget + cooldown** を
  wrapper に。floor/ceiling と併せて。
- **4a** tfvars 不在で `terraform plan` が対話 var prompt → hang。wrapper は `test -f terraform.tfvars` を gate に。
- **4b** CodeCommit に review artifact 無し → wrapper が commit 前に plan JSON + diff を **issue に添付**（人間可読な痕跡）。

## §B  hardened 案B の権限設計（review section B）

**AWS sub-profile `pve-resize`（新 IAM user/role、`sh1admn` ではない）**:

- `ssm:GetParameter` on `/pve/api-token` + `kms:Decrypt`（`kms:EncryptionContext:PARAMETER_ARN=/pve/api-token`
  かつ `kms:ViaService=ssm.<region>.amazonaws.com` でスコープ — 既存 `pve-bootstrap-iam.tf` の scoped-Decrypt を踏襲）。
- S3/DynamoDB は **PVE-CT 専用 state のみ**（新 backend key 例 `pve-lxc.tfstate`）: その key の
  `s3:GetObject/PutObject`、bucket prefix の `s3:ListBucket`、lock table の `dynamodb:GetItem/PutItem/DeleteItem`。
  **← PVE LXC リソースを独自 state に分離することが前提**。分離しないと state read で全 secret（random_password,
  captured SSM, tls key）が漏れ、"least-privilege" が exfiltration で admin 相当になる。
- **その他は全て deny/omit**: `iam:*`/`rds:*`/`route53:*`/`ec2:*`/`sns:*`/`ce:*`、scoped Decrypt 以外の `kms:*` 無し。

**PVE side（新 token、`root@pam!terraform` ではない）**:

- 専用 PVE user+token（例 `svc-resize@pve!selfheal`、privsep=1）。
- 新 PVE role: **`VM.Audit`, `VM.Config.Memory`, `VM.Config.CPU` のみ**。`VM.Allocate`（create/destroy）/`VM.Config.Disk`
  /`VM.Config.Network`/`VM.Config.Options`/`VM.Console`/`Datastore.*`/`SDN.*` は付与しない。
- role を **per-CT ACL パス**で付与（allowlist の CT ID のみ、例 `/vms/104`, `/vms/107`）— datacenter `/` でない。
  token を新 SSM パスに置き sub-profile が読む。
- 結果: token は CT を create/destroy 不能、disk/network/mount 触れず、allowlist の CT にしか届かない
  → prompt-gate が sole boundary でなく defense-in-depth になる。（bpg 0.66 は read-back に `VM.Audit` 必要）。

## 実装内訳（依存順）

**前提（owner の admin 操作 — 自律ループには渡せない、人間が provision）**:

1. **PVE**: `svc-resize@pve` user + role（Memory/CPU/Audit）+ per-CT ACL + token 発行 → 新 SSM パスへ格納。
2. **home-monitor（CodeCommit, terraform, owner apply）**:
   - PVE LXC リソースを**別 state に分離**（`terraform state mv` or 新 workspace/backend key）。← 最もリスキー、慎重に。
   - `pve-resize` IAM user/policy（§B）を TF で定義 → apply。
   - resize 経路用 provider が新 PVE token を使う設定。

**setup（PR-3b、上記 provision 後）**:

3. `infra-resize-allowlist.json`: `{ct, allow_fields:["memory","cores"], min_memory_mb, max_memory_mb, min_cores,
   max_cores, per_ct_daily_budget}`、increase-only。
4. `self-heal-infra-apply.sh`（**非LLM wrapper、apply verb はここだけ**）: 入力 `{ct, target_mb, target_cores}` を
   allowlist∩caps∩floor∩increase-only∩budget で検証 → `contracts/devices.json` を deterministic 編集 →
   `AWS_PROFILE=pve-resize terraform plan -out` → `terraform show -json` を **fail-closed 全走査**（1b）→
   通過時のみ commit + `terraform apply <planfile>`。`test -f terraform.tfvars` gate（4a）。plan JSON+diff を issue 添付（4b）。
5. SKILL Phase 3 case: opus は `self-heal-infra-apply.sh` に `{ct, target_mb, target_cores}` を渡すだけ
   （apply verb を持たない）。境界 #8 を「案B-hardened: increase-only な CT memory/cores resize は
   pve-resize profile + 非LLM wrapper + fail-closed plan-gate 経由でのみ自律、それ以外の home-monitor TF は
   needs-human」に更新。

## DONE gate（PR-3b、hardened）

1. `self-heal-infra-apply.sh --self-test`: fixture A（target memory **increase** in-place, 0 destroy）→ approve;
   B（delete/replace/対象外変化）→ abort; C（cap 超過）→ refuse; **D（decrease / floor 割れ）→ refuse**（新）;
   E（budget 超過）→ refuse（新）。全 exit 期待通り。
2. `jq empty infra-resize-allowlist.json` + schema（min/max 両方 + budget）+ `grep -c rootfs`==0。
3. wrapper が **apply verb を持つ唯一の場所**であることの確認（SKILL grep: opus は `{ct,target_mb,target_cores}`
   提案のみ、`terraform apply` を SKILL 手順に直書きしない）。
4. capability: `AWS_PROFILE=pve-resize aws sts get-caller-identity` が **non-admin** identity。PVE token が
   `VM.Config.Memory/CPU` のみ（`pveum` 確認）。
5. `bin/lint-cookbooks` + dry-run + CI green。
6. e2e（supervised）: allowlist の CT で +256MB increase → plan in-place → wrapper apply → `pct config` 反映 →
   decrease/対象外 plan で abort を別途確認。

## Blockers: 0（hardened 案B、上記緩和を全実装した場合）

hardened 案B は 3 blocker（1a floor / 2a admin-gate / 2c PVE scope）+ 補助 risk を上表で緩和する。
**ただし blockers:0 は設計上の到達点であり、§B の provision（PVE role + IAM sub-profile + state 分離）と
非LLM wrapper の実装が完了して初めて実効**。provision 前に PR-3b のループ側コードを書いても、
apply 経路が admin のままなら blocker 2a/2c が残る。
