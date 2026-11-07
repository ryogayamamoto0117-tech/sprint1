# Sprint 7 — Terraform Remote State × GitHub Actions × OIDC × KMS × 承認付きApply

> **Project Nexus / 実践記録**  
> 実施期間：2026年10月中旬〜2026年11月7日（最終動作検証：2026-11-07）  
> 起点：Sprint 6のローカルTerraform Stateを安全にS3へ移行する段階  
> 作業環境：Windows / PowerShell / VS Code / Git / GitHub CLI / AWS CLI  
> 対象リポジトリ：`ryogayamamoto0117-tech/sprint1`  
> 最終検証ブランチ：`master`  
> Terraform作業ディレクトリ：`infra/sprint6/`（Sprint 6の構成を継続使用）  
> AWSリージョン：`ap-northeast-1`（東京）  
> **到達点：Terraform StateのS3移行から、GitHub Actionsでの検証、OIDC認証、PlanのKMS暗号化、GitHub Environmentでの人間の承認、Terraform Apply、AWS実環境の変更確認まで一通り成功。**

**記録上の注意：** 本書は、Sprint 6の学習記録、Sprint 7開始時の引き継ぎ資料、過去の作業報告、GitHub Actionsのログ・スクリーンショット、AWS CLIの実行結果をもとに再構成した。実際の成果が確認できた箇所は「確認済み」、当時の方針や代表的な設定例は「設計／例」、実行ログが残っていないものは「要再確認」と区別する。ローカルおよびGitHubのリポジトリ全体を本書作成時点で改めて直接監査したものではない。

---

## 1. Sprintの目的と最終結果

### 1.1 Sprint 6からの課題

Sprint 6では、Terraformを使って既存のVPC・ALB・RDSなどを再利用しつつ、ECS/Fargate、セキュリティグループ、CloudWatch Logs、IAM、ターゲットグループ、ALBリスナールールなどをIaC（Infrastructure as Code）で管理した。`terraform plan`で差分を読み、`terraform apply`で反映し、AWS CLIとHTTPの疎通試験で動作を確認した。

一方、当時の運用には次の課題が残っていた。

1. **Terraform Stateがローカル管理**：PCに依存し、共有・バックアップ・排他制御が十分ではない。
2. **コード検証が手作業中心**：コミットやPull RequestのたびにTerraformを継続的に検証できない。
3. **AWS認証と権限分離が不十分**：GitHub Actionsから安全にTerraform Planを実行する仕組みを設計する必要がある。
4. **PlanとApplyのレビュー工程が弱い**：差分を確認したうえで、誰がいつAWSを変更するのかを制御したい。
5. **トラブルシューティング能力を鍛えたい**：IAM、OIDC、State、KMS、GitHub Actionsなどを横断して原因を切り分けたい。

### 1.2 目標

**「AWSリソースを作れる」から、「インフラの変更を安全に計画・レビュー・適用・検証できる」へ進むこと。**

当初のSprint 7の計画は「Remote State、GitHub ActionsのCI、OIDCによるPlan、異常系の検証、必要に応じてローカルからApply」だった。その後、実践を進める中で設計を拡張し、**GitHub Actions内でPlanとApplyを別ジョブに分け、Environmentの手動承認を通してApplyする方式**まで実装した。

重要なのは、**Pushだけで無条件に本番変更する自動Applyではない**こと。Workflow自体は手動起動し、Planで内容を確認し、承認しなければApplyジョブは進まない。

### 1.3 最終結果（確認済み）

| 検証項目 | 実際の結果 | 判定 |
|---|---|---|
| 既存StateのS3移行 | `terraform init -migrate-state`による移行成功、S3 Backendを使用 | 成功 |
| Remote State参照 | S3 Backendから管理対象19件を確認、移行後のPlanで`No changes`を確認 | 成功 |
| S3側の保護 | Versioning、SSE-S3、公開ブロック、HTTPS必須ポリシーを設定 | 設定済み |
| State Lock | `use_lockfile = true`を採用 | 設定済み（競合試験は未確認） |
| Terraform CI | `fmt`、`validate`、`plan`をGitHub Actionsで実行 | 成功 |
| GitHub → AWS認証 | OIDC経由のPlan用Role引き受け | 成功 |
| Plan用IAM最小権限の調整 | 読み取りAPIの不足を特定し修正 | 実施 |
| Plan暗号化 | AWS KMS + Python AES-GCM | 成功 |
| Artifact保存 | `terraform-plan`というArtifactを作成 | 成功 |
| Environment保護 | `terraform-apply`でRequired reviewers、`master`制限 | 動作確認済み |
| Apply用Role | Environment条件付きOIDCで認証 | 成功 |
| Terraform Apply | GitHub ActionsのApplyジョブが正常終了 | 成功 |
| AWS実リソース更新 | CloudWatch Logsの保持期間が14日→30日 | **AWS CLIで確認済み** |
| 想定外の作成・削除 | 最終Planは`0 to add, 1 to change, 0 to destroy` | 計画段階で0件 |
| GitHub履歴 | Workflowと検証用Terraform変更をCommit・Push | 成功 |
| 最終コスト・本番水準の監査 | 請求額、IAM権限の全面監査、復旧試験までは未完了 | 今後の課題 |

> **結論：** GitHubのTerraformコードを起点に、Terraform Planで差分を確認し、KMSでPlanを暗号化し、人間が承認した後で同じPlanをApplyし、AWSの実際の設定が変わったことまで証明できた。Sprint 7は単なるTerraformの練習ではなく、**IaCのCI/CDパイプラインを最後まで接続したSprint**となった。

---

## 2. Sprint 7の全体構成

### 2.1 最終アーキテクチャ

```text
開発PC（Windows / VS Code / PowerShell）
  |
  | ① infra/sprint6/*.tf を変更
  | ② git add → commit → push
  v
GitHub リポジトリ: ryogayamamoto0117-tech/sprint1
  |
  +--> [Terraform CI: terraform.yml]
  |      push / pull_request（対象パスに限定）
  |      terraform fmt -check -recursive
  |      terraform init -backend=false
  |      terraform validate
  |      master上のpush時など条件に応じてAWS OIDC認証・Plan
  |
  +--> [Terraform Apply: terraform-apply.yml]
         workflow_dispatch（人間が手動起動）
         |
         v
       Job 1: Terraform Plan
         ├─ GitHub OIDC → AWS STS → Plan用IAM Role
         ├─ S3 Remote State参照（必要なロック操作も実施）
         ├─ terraform init
         ├─ terraform plan -out=tfplan
         ├─ 変更計画の要約を出力
         ├─ AWS KMS: GenerateDataKey（AES-256データキー）
         ├─ Python: AES-GCMでtfplanを暗号化
         ├─ 平文のtfplanを削除
         └─ 暗号文・暗号化データキー・NonceをArtifactへ
                  |
                  v
         GitHub Environment: terraform-apply
           Required reviewers / masterのみ
           人間が差分を確認 → 承認
                  |
                  v
       Job 2: Terraform Apply
         ├─ GitHub OIDC → AWS STS → Apply用IAM Role
         ├─ terraform init（同じS3 Backend）
         ├─ 暗号化Artifactをダウンロード
         ├─ AWS KMS: Decrypt（データキー復号）
         ├─ Python: AES-GCMでPlanを復号
         ├─ terraform showで保存済みPlanを確認
         └─ terraform apply -input=false tfplan
                  |
                  v
              AWS API
                  |
                  v
         CloudWatch Logs: /ecs/sprint6-app
             retentionInDays: 14 → 30
                  |
                  v
         S3 Remote StateもTerraformにより更新
                  |
                  v
         AWS CLIで実際の保持期間30日を再確認
```

### 2.2 各コンポーネントの責務

| 要素 | 役割 |
|---|---|
| `.tf`ファイル | 実現したいAWSの構成（Desired State）を宣言 |
| S3 Backend | Terraformの管理情報（State）を保管 |
| S3 Lockfile | 同一Stateへの並列変更の競合を防止 |
| Git / GitHub | HCLとWorkflowの変更履歴、レビューの基盤 |
| Terraform CI | 書式・構成・実環境差分の検査 |
| `workflow_dispatch` | Apply用Workflowを意図的に起動 |
| OIDC / AWS STS | 長期AWSアクセスキーを保存せず、一時認証情報を得る |
| Plan用Role | 読み取り・State参照・Plan暗号化などに権限を限定 |
| AWS KMS | データキーの生成・復号を保護 |
| AES-GCM | Terraform Planの機密性と改ざん検出を提供 |
| GitHub Artifact | ジョブ間で暗号化済みPlanを受け渡す |
| GitHub Environment | Applyの前にレビュー・承認を要求 |
| Apply用Role | 承認後、必要なAWS変更操作を実行 |
| AWS CLI | Terraformとは別経路で実環境を検証 |

### 2.3 当初計画から変わったこと

最初の設計では「GitHub ActionsでPlanまで実行し、Applyはローカルで手動実施」が想定されていた。最終的には次のように発展した。

```text
当初: GitHub Actions CI → 手動Plan → ローカルApply
最終: GitHub Actions CI → 手動Workflow → Plan
      → KMS暗号化 → 人間の承認 → GitHub Actions Apply
```

この設計変更により、**Planを作る環境とApplyを実行する環境をGitHub Actions内で統一**し、保存済みPlanを引き渡して承認後に適用する形になった。ただし、承認済みPlanの実際の適用前にはStateの変更やPlanの期限切れなどによって失敗する可能性があり、成功を無条件に保証するものではない。

---

## 3. 作業の時系列

| 時期 | 実施内容・到達点 |
|---|---|
| **2026-10-11** | Sprint 6完了。Sprint 7のテーマとP0〜P5の方針を決定。開始時点ではまだState移行のAWS実作業は未開始 |
| **2026-10-13** | `terraform init -migrate-state`でローカルStateをS3 Backendへ移行。19リソースの管理情報を確認し、`No changes`による整合性確認 |
| **2026-10-17前後** | Terraform CIで`fmt`・`validate`・OIDC認証によるPlanを成功させ、`No changes`を確認 |
| **2026-10-18前後** | Terraform PlanのIAM読み取り権限不足などを調査・修正。`ec2:DescribeVpcAttribute`などの不足を経験 |
| **10月後半** | Plan/Applyロール分離、Environment承認、KMS暗号化による保存済みPlanの受け渡しを設計・構築 |
| **11月初旬** | `terraform-apply.yml`、IAMポリシーJSON群、暗号化・復号Pythonスクリプトをレビュー。`actionlint`、JSON構文、Gitの差分・除外設定を確認 |
| **2026-11-07 前半** | WorkflowをGitHubへPush。Plan用KMS権限が`implicitDeny`になる問題をキーARNの誤字と特定して修正 |
| **2026-11-07 初回実行** | 手動WorkflowでPlan成功、KMS暗号化、Artifactアップロード、Environment承認待ちまで確認。変更なしのため承認せずキャンセル |
| **2026-11-07 最終実行** | 保持期間14日→30日をCommit・Push。Terraform CI成功、手動Planで更新1件を確認、承認後Apply成功、AWS CLIで30日を確認 |

**注記：** 前半の細かい操作日・コマンドの全履歴を本書では再取得していないため、確認できている日付と代表的なコマンドを記載した。「検討・構築」と記した部分の個別AWS CLI操作順序は推定で補完しない。

---

## 4. P0 — 移行前の確認とStateの保護

### 4.1 Stateの役割を改めて整理

Terraformの状態管理では、次の3つを分けて考える必要がある。

```text
HCL（main.tf、ecs.tf、iam.tfなど）
    → 自分が実現したいAWS構成

Terraform State（terraform.tfstate）
    → 管理対象の実リソースID・属性・依存関係などの記録

AWS実環境
    → 現時点で実際に存在しているリソースと設定
```

Stateは「AWS実環境そのもの」でも「AWSへ送る命令書」でもない。TerraformがどのAWSリソースを管理しているかを追跡するための管理情報であり、Providerは通常のPlan時に実環境を参照して差分を計算する。

### 4.2 移行時に重視した安全性

- 移行前のAWSアカウント・リージョンを確認する。
- ローカルStateが参照していたAWSリソースを保持する。
- Stateは機密情報を含む可能性があるため、GitHubへコミットしない。
- S3 Backendの移行を、AWSリソースの新規作成・削除と混同しない。
- State保管用S3バケットは、Sprint 6のアプリケーション用Terraformリソースとは別のライフサイクルにする。
- 移行後の`terraform plan`で意図しない差分がないことを確認する。

参考コマンド：

```powershell
aws sts get-caller-identity
terraform state list
terraform plan -input=false
```

`aws sts get-caller-identity`は、現在どのAWSアカウント・プリンシパルを使っているか確認するコマンド。`terraform state list`はStateに登録されたリソースアドレスを表示する。これらは状態調査に使い、State本体を公開しない。

**記録上の範囲：** 移行の成功と管理対象19件・Plan整合性確認は把握できているが、バックアップファイルの作成場所や復元テストの実施結果は残っていないため、実施済みとは記載しない。

---

## 5. P1 — S3 Remote Stateの構築と移行

### 5.1 採用したBackend設定

Sprint 7のS3 Backendは、以下の設定で管理された。

| 項目 | 値 |
|---|---|
| Backend | `s3` |
| バケット | `terraform-state-237575223564-ap-northeast-1` |
| Stateオブジェクトのキー | `project-nexus/sprint6/terraform.tfstate` |
| リージョン | `ap-northeast-1` |
| ロック方法 | `use_lockfile = true` |
| DynamoDBロックテーブル | 新設しない |

`infra/sprint6/backend.tf`の主要部分は次の形。

```hcl
terraform {
  backend "s3" {
    bucket       = "terraform-state-237575223564-ap-northeast-1"
    key          = "project-nexus/sprint6/terraform.tfstate"
    region       = "ap-northeast-1"
    use_lockfile = true
  }
}
```

上記は**確認されたBackendパラメータをまとめた主要構成の再現例**。現物ファイルのコメントや空白まで一致することを保証するものではない。

### 5.2 S3バケットを保護する設定

| セキュリティ設定 | 実施した内容 | 理由 |
|---|---|---|
| Public Access Block | 4項目をブロック | インターネットへの意図しない公開を防ぐ |
| Versioning | 有効 | 誤操作時に過去バージョンを参照・復旧しやすくする |
| サーバー側暗号化 | SSE-S3（AES-256） | 保存時の暗号化 |
| HTTPS必須 | バケットポリシーで非TLSアクセスを拒否 | 通信経路を保護 |
| IAM権限 | StateとLockfileへの操作を用途別に限定 | 不要な参照・上書きを避ける |
| 管理範囲 | State用バケットをアプリ環境から分離 | アプリの`destroy`によるState保管先喪失を防ぐ |

例：非HTTPS通信を拒否するバケットポリシーの基本思想。

```json
{
  "Effect": "Deny",
  "Principal": "*",
  "Action": "s3:*",
  "Resource": [
    "arn:aws:s3:::terraform-state-237575223564-ap-northeast-1",
    "arn:aws:s3:::terraform-state-237575223564-ap-northeast-1/*"
  ],
  "Condition": {
    "Bool": {
      "aws:SecureTransport": "false"
    }
  }
}
```

これは**仕組みを説明するための代表的なStatement例**であり、現行バケットポリシー全文の引用ではない。

### 5.3 ローカルStateからの移行

実際の移行で使用した重要なコマンド：

```powershell
terraform init -migrate-state
```

- `init`：Terraformの作業ディレクトリを初期化する。
- `-migrate-state`：Backendの変更に伴い、既存Stateを新しいBackendへ移行するオプション。
- **空のStateを新規作成してAWSリソースを作り直す操作ではない。**

既存StateをS3へ移した後、S3 Backendから**19件のTerraform管理対象**が読み取れることを確認。続いてPlanで**`No changes`**を確認した。

```text
既存のローカルState
        |
        | terraform init -migrate-state
        v
S3: project-nexus/sprint6/terraform.tfstate
        |
        | terraform state list / terraform plan
        v
既存AWSリソースとの管理上の対応を維持
        → 不要なリソースの再作成・削除なし
```

### 5.4 `terraform init -reconfigure`との違い

| コマンド | 用途 |
|---|---|
| `terraform init -migrate-state` | 既存のStateを別Backendへ移行する |
| `terraform init -reconfigure` | 保存済みのBackend初期化設定を破棄し、現在の設定で再初期化する。State移行の代替ではない |
| `terraform init -backend=false` | Backendの初期化を行わず、書式・構成検証などに使う |

今回、**State移行の段階では`-migrate-state`**を使い、GitHub Actionsで既存のS3 Backendを初期化する段階では`-reconfigure -input=false`を使った。

### 5.5 `use_lockfile = true`を選んだ理由

Terraform Stateは複数人や複数ジョブが同時に書き換えると整合性が壊れる恐れがある。S3 Backendのネイティブロックファイル方式を利用することで、同一Stateに対する競合操作を防ぐ設計とした。

```hcl
use_lockfile = true
```

ロックには、Stateオブジェクトとは別の`*.tflock`オブジェクトの作成・参照・削除などが関係する。そのため、**Plan用Roleも単純なS3 GetObjectだけでは足りない場合がある**。

追加で、GitHub Actions側には次の`concurrency`設定を使用した。

```yaml
concurrency:
  group: terraform-sprint6
  cancel-in-progress: false
```

- **S3 Lockfile**：Stateレベルの競合防止。
- **GitHub Actions Concurrency**：同じグループのWorkflow実行を並列させない制御。

この2つは代替ではなく防御層が異なる。ローカルTerraformからの操作もあるため、GitHub側の排他制御だけでStateロックの代わりにはならない。

**未検証として残すこと：** 2つのTerraform操作を意図的に競合させたロック実験と、StateのS3過去バージョンからの復元訓練は、本記録では実施を確認できない。

---

## 6. P2 — GitHub ActionsによるTerraform CI

### 6.1 CIの目的

GitHubへTerraformコードをPushしたりPull Requestを作成したりした際に、少なくとも基本的な書式・構成エラーを自動で検出する。Terraformの変更を、個人PCだけでなく共通のCI環境でも検証する仕組みを整備した。

ワークフローファイル：

```text
.github/workflows/terraform.yml
```

### 6.2 起動条件と変更ファイルの限定

確認した起動条件の主要部分：

```yaml
name: Terraform CI

on:
  push:
    branches:
      - master
    paths:
      - 'infra/sprint6/**'
      - '.github/workflows/terraform.yml'

  pull_request:
    branches:
      - master
    paths:
      - 'infra/sprint6/**'
      - '.github/workflows/terraform.yml'

  workflow_dispatch:
```

- `push`：指定されたブランチ・ファイル条件に一致するPushで起動。
- `pull_request`：`master`向けの対象変更のPRで起動。
- `workflow_dispatch`：GitHub Actions画面などから手動起動できる。
- `paths`：Terraformに関係する変更だけでTerraform CIを実行するためのフィルター。

### 6.3 CIの検証ステップ

実装した主要コマンド：

```yaml
- name: Check Terraform formatting
  run: terraform fmt -check -recursive

- name: Initialize Terraform without backend
  run: terraform init -backend=false -input=false

- name: Validate Terraform configuration
  run: terraform validate
```

| コマンド | 確認できること | 確認できないこと |
|---|---|---|
| `terraform fmt -check -recursive` | HCLが標準フォーマットになっているか | AWSリソースの正常性 |
| `terraform init -backend=false -input=false` | Backendを使わない構成検証の準備 | Remote Stateを正しく読めるか |
| `terraform validate` | Terraform構成のスキーマ・参照関係など | IAM権限、AWSのクォータ、実際の作成可否 |
| `terraform plan` | 実態を踏まえた追加・更新・削除の計画 | その後のApply成功やアプリ動作 |

### 6.4 PRとmasterでAWS権限を分ける

確認済みのWorkflowでは、以下の条件を付けていた。

```yaml
- name: Configure AWS credentials
  if: github.event_name != 'pull_request' && github.ref == 'refs/heads/master'
  uses: aws-actions/configure-aws-credentials@v4
  with:
    role-to-assume: arn:aws:iam::237575223564:role/terraform-plan-github-actions-role
    aws-region: ap-northeast-1

- name: Initialize Terraform with S3 backend
  if: github.event_name != 'pull_request' && github.ref == 'refs/heads/master'
  run: terraform init -reconfigure -input=false

- name: Plan Terraform changes
  if: github.event_name != 'pull_request' && github.ref == 'refs/heads/master'
  run: terraform plan -input=false
```

**重要：現在の`terraform.yml`では、Pull Request時にAWS実環境を使ったPlanは実行しない。** PRで通るのは書式・初期化・Validate等であり、実環境を参照したPlanは`master`上のPushや手動起動など、条件に一致するときに実行される。

この分離は、公開リポジトリで未確認のPRコードへAWS権限を渡さないための基本的な安全対策。

### 6.5 実際のCI検証結果

2026年10月17日前後には、`fmt`、`validate`、OIDCを使ったPlanを成功させ、`No changes`を確認した。

最終検証の2026年11月7日には、保持期間を14日から30日に変更して`master`へPushした際、Terraform CIが自動起動した。

- GitHub Actions Run：[`42337948445`](https://github.com/ryogayamamoto0117-tech/sprint1/actions/runs/42337948445)
- `validate`ジョブ：**Success**
- `Check Terraform formatting`：成功
- `Initialize Terraform without backend`：成功
- `Validate Terraform configuration`：成功
- AWS認証・S3 Backend初期化・`Plan Terraform changes`：成功
- ジョブ実行時間：約28秒（画面の観測値）

これで、TerraformコードをGitHubへPushするとCIが起動し、AWSへ適用する前に変更計画を検証できる流れが確認できた。

### 6.6 既存Docker用CIとの分離

`container-build.yml`には次のようなパスフィルターがあった。

```yaml
on:
  push:
    branches:
      - master
    paths:
      - 'src/**'
      - 'pom.xml'
      - 'mvnw'
      - '.mvn/**'
      - 'Dockerfile'
      - '.dockerignore'
```

そのため、今回の`infra/sprint6/main.tf`だけの変更では、**Sprint 4用Dockerイメージのビルド・ECR Pushを起動しない**構成だった。

なお、Workflowが`push`イベントを持っているだけでは「すべてのPushで起動する」とは限らない。`branches`と`paths`を合わせて確認することが重要。

---

## 7. P3 — GitHub Actions OIDCとAWS IAM Role

### 7.1 OIDCを使う理由

GitHub ActionsからAWS CLIやTerraformを利用するにはAWS認証が必要。しかし、IAMユーザーの長期アクセスキーをGitHub Secretsへ保存し続ける方式は、漏えい・ローテーション・権限管理のリスクがある。

今回採用したのは**OpenID Connect（OIDC）**。

```text
GitHub Actions
   |
   | GitHubが署名したOIDC ID Token
   v
AWS STS (Security Token Service)
   |
   | 信頼ポリシーの条件を評価
   | sts:AssumeRoleWithWebIdentity
   v
一時的なAWS認証情報
   |
   v
Terraform Plan / Apply のAWS API操作
```

GitHub ActionsがAWSで「誰として操作できるか」はRoleの信頼ポリシーが決め、そのRoleとして「何ができるか」は権限ポリシーが決める。

### 7.2 Plan用・Apply用のRoleを分離

| IAM Role | 目的 | 主要な許可の方向性 |
|---|---|---|
| `terraform-plan-github-actions-role` | Planを作成 | AWSリソースの参照、State読取とロック、KMSデータキー生成 |
| `terraform-apply-github-actions-role` | 承認後にApply | 必要な変更API、State更新、KMS復号、各種参照 |

「Planは何も変更しないので完全読み取り専用」と表現しない。State Lockのオブジェクト作成・削除など、**Planを安全に動かすために必要な補助的書込み**はある。またKMSの`GenerateDataKey`も呼び出す。

### 7.3 Plan用Roleの信頼ポリシー

AWS CLIで実際に確認した主要部分：

```json
{
  "Effect": "Allow",
  "Principal": {
    "Federated": "arn:aws:iam::237575223564:oidc-provider/token.actions.githubusercontent.com"
  },
  "Action": "sts:AssumeRoleWithWebIdentity",
  "Condition": {
    "StringEquals": {
      "token.actions.githubusercontent.com:aud": "sts.amazonaws.com"
    },
    "StringLike": {
      "token.actions.githubusercontent.com:sub": "repo:ryogayamamoto0117-tech@311000617/sprint1@1381177800:ref:refs/heads/master"
    }
  }
}
```

- `Principal.Federated`：信頼するGitHubのOIDC Provider。
- `sts:AssumeRoleWithWebIdentity`：Web ID Tokenを使ってRoleを引き受けるSTS操作。
- `aud`（Audience）：AWS STS向けトークンであることを要求。
- `sub`（Subject）：リポジトリと`master`ブランチに相当する識別条件。
- `@311000617`、`@1381177800`：GitHubのアカウント・リポジトリIDを含むカスタムSubject形式。

一般的な`repo:OWNER/REPO:ref:refs/heads/master`と文字列が異なる点に注意。今回の実行では、このGitHub側のカスタムSubjectとAWS側の条件が実際に一致し、Plan用Roleで認証できた。

### 7.4 Apply用Roleの信頼ポリシー

こちらはブランチではなく、**Environment**をSubjectの条件とした。

```json
{
  "Effect": "Allow",
  "Principal": {
    "Federated": "arn:aws:iam::237575223564:oidc-provider/token.actions.githubusercontent.com"
  },
  "Action": "sts:AssumeRoleWithWebIdentity",
  "Condition": {
    "StringEquals": {
      "token.actions.githubusercontent.com:aud": "sts.amazonaws.com",
      "token.actions.githubusercontent.com:sub": "repo:ryogayamamoto0117-tech@311000617/sprint1@1381177800:environment:terraform-apply"
    }
  }
}
```

Applyジョブは`environment: terraform-apply`に属するため、承認ルールを通過した後に、このEnvironmentを含むSubjectでAWS認証を行う設計になっている。

### 7.5 IAMの検証・修正

PlanをGitHub Actions上で動かす中で、AWS Providerが実際に呼び出す読み取りAPIを調べ、権限不足に対応した。

実際に経験した例：

- `ec2:DescribeVpcAttribute`の不足を特定し、Plan用Roleの読み取り権限を修正した。
- `TerraformPlanReadOnlyAccess`のバージョン`v3`には、VPC／Subnet／SG／ECS／ALB／CloudWatch Logs／IAMロール等の読み取りAPIを記述した。
- IAMロール参照には、`iam:GetRole`、`iam:GetRolePolicy`、`iam:ListRolePolicies`、`iam:ListAttachedRolePolicies`、`iam:ListRoleTags`などが必要になる場合がある。
- AWS管理ポリシーの参照には、`iam:GetPolicy`、`iam:GetPolicyVersion`を使用した。

当時の実確認の例（`TerraformPlanReadOnlyAccess` v3からの抜粋）：

```json
{
  "Sid": "ReadSprint6IamRole",
  "Effect": "Allow",
  "Action": [
    "iam:GetRole",
    "iam:GetRolePolicy",
    "iam:ListRolePolicies",
    "iam:ListAttachedRolePolicies",
    "iam:ListRoleTags",
    "iam:ListInstanceProfilesForRole"
  ],
  "Resource": "arn:aws:iam::237575223564:role/sprint6-ecs-task-execution-role"
}
```

**学び：** IAMポリシーを「とりあえずAdministratorAccess」に広げるのではなく、エラーになったAWS APIを確認し、必要なAction・Resourceを絞って追加する。

### 7.6 実際にRoleにアタッチされていたポリシー

Plan用Roleで確認した3件：

```text
TerraformPlanKMSGenerateDataKeyAccess
TerraformPlanS3StateAccess
TerraformPlanReadOnlyAccess
```

Apply用Roleで確認した9件：

```text
TerraformApplyS3StateWriteAccess
TerraformApplyKMSDecryptAccess
TerraformPlanS3StateAccess
TerraformPlanReadOnlyAccess
TerraformApplyEC2SGAccess
TerraformApplyLogsAccess
TerraformApplyALBAccess
TerraformApplyIAMAccess
TerraformApplyECSAccess
```

AWSに対して実際に許可されているかは、ポリシー名だけでは判断できない。アタッチ、ポリシーの現在のデフォルトバージョン、Action、Resource、Condition、Permissions Boundary、SCPなどを合わせて評価する必要がある。

---

## 8. GitHub Environmentによる人間の承認ゲート

### 8.1 Environmentの設定

Environment名：`terraform-apply`

2026年11月7日にGitHubのSettings → Environmentsの画面で確認した設定：

| 設定 | 実際の状態 |
|---|---|
| Required reviewers | 有効 |
| 承認者 | `ryogayamamoto0117-tech` |
| Prevent self-review | 無効 |
| Allow administrators to bypass configured protection rules | 無効 |
| Deployment branches and tags | Selected branches and tags |
| 許可ブランチ | `master`、1ブランチのみ |

### 8.2 Workflow側の設定

```yaml
jobs:
  apply:
    needs: plan
    if: github.ref == 'refs/heads/master'
    runs-on: ubuntu-latest
    environment: terraform-apply
```

- `needs: plan`：Planジョブが成功した後にApplyジョブへ進む。
- `if: github.ref ...`：`master`以外ではApplyさせない追加条件。
- `environment: terraform-apply`：そのEnvironmentの保護ルールを適用する。

**重要：** `needs: plan`はPlanに変更があるかどうかを判断するものではない。最初のテストでは`No changes`でも承認待ちになった。今後は「変更0件ならApply不要」と判定する仕組みを追加する余地がある。

### 8.3 承認とIAM Roleは別のセキュリティ層

```text
GitHub Environmentの承認
    → ジョブ実行の開始を制限

AWS IAM Roleの信頼ポリシー
    → 認証可能なGitHubトークンを制限

AWS IAM Roleの権限ポリシー
    → 実際に変更可能なAWS操作を制限
```

承認があるからIAM権限を広げてよいわけではない。逆にIAM権限が正しくても、承認ゲートなしで変更が適用される運用にはしない。

---

## 9. Terraform PlanをKMSとAES-GCMで暗号化する

### 9.1 なぜPlanファイルを暗号化するのか

Terraformの`-out=tfplan`で保存されるPlanは、単なるテキスト要約ではなく、適用に必要な構成情報を含むバイナリファイル。設定によっては機密情報も含まれ得る。

今回はPlanジョブとApplyジョブが別のRunner上で実行されるため、Planを何らかの形で受け渡す必要があった。そこで、**保存済みPlanをKMSで保護したデータキーを使って暗号化し、暗号化済みファイルのみをArtifactへ保存する**方式を採用した。

### 9.2 Envelope Encryption（エンベロープ暗号化）

```text
AWS KMS Key（alias/terraform-plan）
      |
      | GenerateDataKey(KeySpec = AES_256)
      v
  ┌────────────────────┬──────────────────────┐
  | 平文のデータキー    | KMSで暗号化済みのキー |
  └────────────────────┴──────────────────────┘
             |                   |
             v                   |
  Python AES-GCMでtfplan暗号化      |
             |                   |
             v                   v
          tfplan.enc       tfplan.key.enc
             |
      nonceも別ファイル保存
             v
         tfplan.nonce

    3ファイルをGitHub Artifactへ

承認後：
  KMS Decrypt(tfplan.key.enc) → 平文データキーを復元
  AES-GCM decrypt(tfplan.enc, tfplan.nonce)
            → tfplanを復元 → terraform apply tfplan
```

### 9.3 KMSキーの確認済み設定

| 項目 | 値 |
|---|---|
| Alias | `alias/terraform-plan` |
| Key ID | `e84f02c9-c568-405d-ab58-88c9e3bd032a` |
| KeyState | `Enabled` |
| KeyUsage | `ENCRYPT_DECRYPT` |
| KeySpec | `SYMMETRIC_DEFAULT` |
| リージョン | `ap-northeast-1` |

確認コマンド：

```powershell
aws kms describe-key --key-id alias/terraform-plan --query "KeyMetadata.{KeyId:KeyId,KeyState:KeyState,KeyUsage:KeyUsage,KeySpec:KeySpec}"
```

### 9.4 Plan暗号化用Pythonスクリプト

ファイル：`scripts/encrypt_plan.py`

**GitでCommitされている内容を`git show HEAD:scripts/encrypt_plan.py`で確認した実コード：**

```python
import boto3
import os
from cryptography.hazmat.primitives.ciphers.aead import AESGCM

kms = boto3.client("kms")

response = kms.generate_data_key(
    KeyId="alias/terraform-plan",
    KeySpec="AES_256"
)

plaintext_key = response["Plaintext"]
encrypted_key = response["CiphertextBlob"]

nonce = os.urandom(12)

with open("infra/sprint6/tfplan", "rb") as f:
    plan_data = f.read()

aesgcm = AESGCM(plaintext_key)
encrypted_plan = aesgcm.encrypt(nonce, plan_data, None)

with open("infra/sprint6/tfplan.enc", "wb") as f:
    f.write(encrypted_plan)

with open("infra/sprint6/tfplan.key.enc", "wb") as f:
    f.write(encrypted_key)

with open("infra/sprint6/tfplan.nonce", "wb") as f:
    f.write(nonce)

os.remove("infra/sprint6/tfplan")
```

ポイント：

1. `boto3.client("kms")`でAWS KMSクライアントを作る。
2. `generate_data_key`で平文データキーとKMS暗号化済みデータキーを受け取る。
3. `os.urandom(12)`でAES-GCM用の12バイトNonceを生成する。
4. `AESGCM.encrypt`でPlanを暗号化する。
5. 暗号文、暗号化済みデータキー、Nonceを別々のファイルへ書き込む。
6. Artifactに平文Planを含めないため、最後に`os.remove`する。

**注意：** AES-GCMのNonceは、同じデータキーに対して重複させないことが重要。今回のスクリプトは新しいデータキーを生成し、ランダムNonceを採用している。平文キーはPythonプロセスのメモリ中に存在するため、ログ出力や例外処理などにも配慮する必要がある。

### 9.5 Apply側の復号スクリプト

ファイル：`scripts/decrypt_plan.py`

レビューした主要コード：

```python
import boto3
from cryptography.hazmat.primitives.ciphers.aead import AESGCM

kms = boto3.client("kms")

with open("infra/sprint6/tfplan.key.enc", "rb") as f:
    encrypted_key = f.read()

response = kms.decrypt(
    CiphertextBlob=encrypted_key,
    KeyId="alias/terraform-plan"
)
plaintext_key = response["Plaintext"]

with open("infra/sprint6/tfplan.enc", "rb") as f:
    encrypted_plan = f.read()

with open("infra/sprint6/tfplan.nonce", "rb") as f:
    nonce = f.read()

aesgcm = AESGCM(plaintext_key)
plan_data = aesgcm.decrypt(nonce, encrypted_plan, None)

with open("infra/sprint6/tfplan", "wb") as f:
    f.write(plan_data)
```

`AESGCM.decrypt`は、暗号化時に付加した認証タグを検証する。暗号文やNonceの改ざん、キーの不一致などがあれば、正しく復号できない。

### 9.6 GitHub ActionsでのPython実行環境

- `actions/setup-python@v5`
- `python-version: '3.12'`
- 依存パッケージ：`cryptography==46.0.3`、`boto3`

ローカルWindows環境では、当時`python --version`等から正常なPython実行環境を確認できなかったため、Pythonを無理にインストールせず、GitHub ActionsのRunner上で実行する方針を選んだ。

そのため、**静的なレビュー・タイプミス修正と、GitHub Actionsでの実動作成功を分けて記録する**。

### 9.7 Artifactに保存するファイル

```text
infra/sprint6/tfplan.enc
infra/sprint6/tfplan.key.enc
infra/sprint6/tfplan.nonce
```

暗号化後のチェック：

```bash
test -s infra/sprint6/tfplan.enc
test -s infra/sprint6/tfplan.key.enc
test -s infra/sprint6/tfplan.nonce
test ! -e infra/sprint6/tfplan
```

GitHub Actionsでは`actions/upload-artifact@v4`で`terraform-plan`をアップロードし、`retention-days: 1`を設定した。Applyジョブが`actions/download-artifact@v4`で取得して復号する。

**今回の学び：** Artifactはジョブ間のファイル転送手段であって、それだけで機密性が保証されるわけではない。保存前にPlanを暗号化し、復号権限をApply用Roleへ分ける設計に意味がある。

---

## 10. `terraform-apply.yml`の設計と実装

### 10.1 Workflowの起動方法

ファイル：`.github/workflows/terraform-apply.yml`

```yaml
name: Terraform Apply

on:
  workflow_dispatch:

concurrency:
  group: terraform-sprint6
  cancel-in-progress: false

permissions:
  contents: read
```

**`workflow_dispatch`だけを指定しているので、CommitをPushしただけではApply Workflowは始まらない。** GitHub Actions画面、または`gh workflow run`から人間が起動する。

Planジョブ・Applyジョブの両方に`master`の条件が入っていることを確認した。

### 10.2 Planジョブの主要ステップ

1. `actions/checkout@v4`でコードを取得。
2. `hashicorp/setup-terraform@v3`でTerraform `1.16.5`を用意。
3. `actions/setup-python@v5`でPython `3.12`を用意。
4. Python依存ライブラリをインストール。
5. `aws-actions/configure-aws-credentials@v4`でPlan用RoleをOIDC経由で引き受ける。
6. `terraform init -reconfigure -input=false`でS3 Backendを初期化。
7. `terraform plan -input=false -out=tfplan`でPlanを保存。
8. `terraform show -json tfplan | jq ...`で変更アクションの要約を出す。
9. `python scripts/encrypt_plan.py`でPlanを暗号化。
10. 暗号化済みファイルと平文Plan削除を確認。
11. `actions/upload-artifact@v4`でArtifactを保存。

Plan作成の主要コード：

```yaml
- name: Initialize Terraform with S3 backend
  run: terraform init -reconfigure -input=false

- name: Create Terraform Plan
  run: terraform plan -input=false -out=tfplan

- name: Check Terraform Plan Summary
  run: |
    terraform show -json tfplan |
      jq -r '
        [.resource_changes[]? |
          select(.change.actions != ["no-op"]) |
          .change.actions | join(",")
        ] |
        group_by(.) |
        map("\(.[0]): \(length)") |
        .[]
      '
```

変更件数の要約は便利だが、**件数だけで安全性を判断しない**。`Create Terraform Plan`のログで、対象リソース、属性の変更前後、削除・置換の有無を確認する。

### 10.3 Applyジョブの主要ステップ

1. Planジョブの成功を待つ（`needs: plan`）。
2. `terraform-apply` Environmentによる承認を要求。
3. 承認後、Apply用RoleでOIDC認証。
4. Terraform `1.16.5`とPython `3.12`を用意。
5. S3 Backendを初期化。
6. `terraform-plan` Artifactを取得。
7. `python scripts/decrypt_plan.py`で保存済みPlanを復元。
8. `terraform show -json tfplan > /dev/null`でPlanが読み取れることを確認。
9. `terraform apply -input=false tfplan`で、その保存済みPlanを適用。

**重要：** Applyジョブ内で新しいPlanを作り直すのではなく、Planジョブで生成・レビューした保存済みPlanを復号して使う。これにより、レビューした計画と適用する計画を対応させる。

### 10.4 `defaults.run.working-directory`の注意

Terraformの`run`ステップには`working-directory: infra/sprint6`を指定した。一方で、Pythonスクリプトはリポジトリ直下の`scripts/`にあるため、該当ステップでは`${{ github.workspace }}`を使用した。

- `run`ステップのWorking Directoryと、`uses`アクションが受け取るパスの基準を混同しない。
- Artifactの`path`と、ダウンロード先の`path`を確認する。
- `tfplan.enc`、`tfplan.key.enc`、`tfplan.nonce`がApplyジョブで想定どおり見つかる必要がある。

最終的にPlan・Apply両ジョブが成功したことから、今回のファイル受け渡しは動作した。

---

## 11. IAMポリシーのファイル管理と安全性

### 11.1 リポジトリで管理したIAMポリシー例

WorkflowのCommitで次のファイルを追加した。

```text
iam-policies/
├── alb-apply.json
├── cloudwatch-logs-apply.json
├── ec2-sg-apply.json
├── ecs-apply.json
├── iam-apply.json
└── s3-state-apply.json
```

ポリシーの名称と用途を分けることで、ECS、ALB、Security Group、CloudWatch Logs、IAM、S3 Stateなどの許可を一枚の巨大なJSONにまとめないようにした。

ただし、**JSONをGitHubに置いただけではAWS IAMポリシーが自動更新されるわけではない**。AWS側の実際のアタッチ済みポリシー・現在のバージョンをAWS CLIで別途確認した。

### 11.2 コマンドでポリシーを調査

```powershell
aws iam list-attached-role-policies --role-name terraform-apply-github-actions-role
aws iam list-attached-role-policies --role-name terraform-plan-github-actions-role
aws iam get-policy --policy-arn <POLICY_ARN> --query "Policy.DefaultVersionId" --output text
aws iam get-policy-version --policy-arn <POLICY_ARN> --version-id v1 --query "PolicyVersion.Document"
```

- `get-policy`：管理ポリシーのメタデータを読む。
- `DefaultVersionId`：実際の権限評価に使用されるバージョン。
- `get-policy-version`：そのバージョンのAction・Resource・Conditionなどを読む。

### 11.3 PlanとApplyの権限分離の価値

Planでは主に参照、Applyでは必要な更新操作という境界を設けた。例えばCloudWatch Logsの保持期間変更にはAWS側でロググループの保持ポリシーを更新する権限が必要となる。

一方、`iam:PutRolePolicy`、`iam:UpdateAssumeRolePolicy`のようなIAM操作は、対象Resourceを制限していても権限昇格の経路になる場合がある。今回のApply Roleに付与したIAM操作の網羅的な権限昇格レビューまでは実施を確認していないため、**本番の最小権限が完成したとは判断しない**。

---

## 12. 開発環境・CLI・Gitで行った検証

### 12.1 GitHub CLI（`gh`）の導入

Windows上でGitHub CLIを導入し、`gh auth login`でGitHubに認証した。これにより、ブラウザだけでなくPowerShellからWorkflowの一覧・起動・実行状態を操作できるようになった。

```powershell
gh workflow list --repo ryogayamamoto0117-tech/sprint1
gh workflow run terraform-apply.yml --ref master
gh run view <RUN_ID>
```

- `gh`：GitHub CLI。
- `--repo`：対象Repository（リポジトリ）を指定。短縮形は`-R`。
- `--ref`：実行対象のブランチ・参照を指定。
- `gh run view`：指定したRun IDの実行状態を見る。

`gh workflow list`では、Push直後に`Terraform Apply`が一覧へ追加されたことを確認した。

### 12.2 `actionlint`によるWorkflow構文検証

GitHub ActionsのWorkflow YAMLを事前検査するため、`actionlint`を導入した。

```powershell
actionlint .github/workflows/terraform-apply.yml
```

結果は**出力なし＝指摘なし**。ただし、actionlintはWorkflow構文や式の静的検証であり、AWS IAMの実権限やPlanの復号成功まで証明するものではない。

### 12.3 PowerShellでIAM JSON構文をまとめて検証

```powershell
Get-ChildItem iam-policies -Filter *.json | ForEach-Object {
  Get-Content $_.FullName -Raw | ConvertFrom-Json | Out-Null
  Write-Host "OK: $($_.Name)"
}
```

作成した6ファイルすべてで`OK`を確認。これはJSONとして読み取れることの検証であり、IAMポリシーとして意味が正しいことや適用できることの完全な検証ではない。

### 12.4 `.gitignore`でState・Plan・秘密情報を除外

確認・追記した主なルール：

```gitignore
.env
.terraform/
*.tfstate
*.tfstate.*
*.tfvars
*.tfvars.json
*.tfplan
tfplan
tfplan.enc
tfplan.key.enc
tfplan.nonce
```

`*.tfplan`は`tfplan`のような拡張子のない名前に必ずしも一致しないため、今回使用するファイル名を明示した。`.terraform.lock.hcl`はProviderバージョン固定のためGitで管理する。

確認に使用したコマンド：

```powershell
git check-ignore infra/sprint6/tfplan infra/sprint6/tfplan.enc infra/sprint6/tfplan.key.enc infra/sprint6/tfplan.nonce
git ls-files
git status -sb
git diff --cached --stat
git diff --cached --check
```

**注意：** `git diff --cached --check`は空白などの問題を検出するもので、秘密情報をスキャンするコマンドではない。公開リポジトリへPushする前はファイルの内容と履歴も別途確認する必要がある。

### 12.5 Pythonスクリプトのタイプミス修正

初期レビューでは、暗号化スクリプトに次のタイプミスがあった。

| 誤り | 修正後 |
|---|---|
| `boto3.crient` | `boto3.client` |
| `f.white(encrypted_plan)` | `f.write(encrypted_plan)` |
| `f:write(encrypted_key)` | `f.write(encrypted_key)` |

GitHubへPushした後、ローカルファイルの`Select-String`と`git show HEAD:scripts/encrypt_plan.py`で、Commit済みコードにも修正が含まれていることを確認した。

### 12.6 GitのCommitとPush

Workflow初回登録時に確認したCommit：

```text
742ef57 feat: add Terraform apply workflow with OIDC and KMS encryption
```

このCommitでは、`.github/workflows/terraform-apply.yml`、IAMポリシーJSON、Pythonスクリプト、`.gitignore`の変更を含む10ファイルを記録した。GitHubへPushしたことで、手動起動できるWorkflowとして表示されるようになった。

`terraform-apply.yml`は手動起動のみだが、別Workflowの`push`トリガーには注意が必要。Push前に`terraform.yml`と`container-build.yml`のトリガーや`paths`フィルターを確認した。

### 12.7 PowerShellで学んだこと

```powershell
Get-Content .github/workflows/terraform.yml
Get-Content .github/workflows/container-build.yml
```

PowerShellでは改行して複数コマンドを続けて入力できる。セミコロンでも区切れる。

```powershell
Get-Content .github/workflows/terraform.yml; Get-Content .github/workflows/container-build.yml
```

Gitの`git show`で`(END)`が表示された場合は、Gitのページャー`less`が開いている。`q`（Quit）でPowerShellへ戻る。

---

## 13. トラブルシューティング — KMSキーARNの誤記

### 13.1 発生した症状

2026年11月7日、Plan用RoleのKMSデータキー生成権限をIAM Policy Simulatorで検証すると、想定外の結果になった。

```json
[
  {
    "Action": "kms:GenerateDataKey",
    "Decision": "implicitDeny"
  }
]
```

`implicitDeny`は、評価対象の操作を許可する有効なAllowが見つからないことを意味する。明示的なDenyである`explicitDeny`とは異なる。

### 13.2 原因を段階的に調査

1. `list-attached-role-policies`でPlan用Roleを確認。
2. `TerraformPlanKMSGenerateDataKeyAccess`が**既にアタッチされている**ことを発見。
3. `get-policy`でデフォルトバージョンが`v1`であることを確認。
4. `get-policy-version`で`Action`と`Resource`を確認。
5. `Action`は正しかったが、`Resource`のKMSキーIDに1文字の誤記があった。

誤ったKey ID：

```text
e84f029-c568-405d-ab58-88c9e3bd032a
```

正しいKey ID：

```text
e84f02c9-c568-405d-ab58-88c9e3bd032a
```

**`c`が1文字抜けていた。** IAMはResource ARNが一致しないと許可しない。ポリシー名が適切でも、ActionとResourceが正しく対応していなければアクセスできない。

### 13.3 修正方法

当初は修正用JSONファイルを作る方法も検討したが、今回は変更が1文字だけだったため、**AWS IAMコンソールでカスタマー管理ポリシーを直接編集**した。

- `TerraformPlanKMSGenerateDataKeyAccess`を開く。
- JSONエディターでResource ARNを修正。
- 保存し、新しいポリシーバージョンを作成。
- 既にRoleへアタッチされているポリシーを再アタッチする必要はなかった。

**注意：** コンソールによる変更はTerraformやリポジトリに自動同期されるわけではない。継続的な運用ではIAMポリシーの変更履歴もコードで管理することが望ましい。

### 13.4 再検証

```powershell
aws iam simulate-principal-policy --policy-source-arn arn:aws:iam::237575223564:role/terraform-plan-github-actions-role --action-names kms:GenerateDataKey --resource-arns arn:aws:kms:ap-northeast-1:237575223564:key/e84f02c9-c568-405d-ab58-88c9e3bd032a --query "EvaluationResults[].{Action:EvalActionName,Decision:EvalDecision}"
```

修正後の結果：

```json
[
  {
    "Action": "kms:GenerateDataKey",
    "Decision": "allowed"
  }
]
```

**学び：** `implicitDeny`になったときは、権限を無差別に追加するのではなく、Role → アタッチ済みポリシー → デフォルトバージョン → Action → Resource → Conditionの順に調べる。

---

## 14. トラブルシューティング — KMS Aliasとキーポリシー

### 14.1 `GetKeyPolicy`が失敗

最初は次のコマンドでKMSキーポリシーを読み取ろうとした。

```powershell
aws kms get-key-policy --key-id alias/terraform-plan --policy-name default --query Policy --output text
```

しかし、次のエラーになった。

```text
InvalidArnException:
Key Aliases are not supported for this operation.
```

原因は、`GetKeyPolicy`がこの操作でAliasを受け付けないこと。すべてのKMS APIが同じ`KeyId`表現を受け付けるわけではない。

### 14.2 Key IDへ変更して成功

```powershell
aws kms get-key-policy --key-id e84f02c9-c568-405d-ab58-88c9e3bd032a --policy-name default --query Policy --output text
```

確認できたキーポリシーには、主に次のStatementがあった。

1. `Enable IAM User Permissions`：アカウントの`root`プリンシパルに`kms:*`を許可。
2. `Allow access for Key Administrators`：管理用IAMユーザーにKMSキー管理操作を許可。

### 14.3 `root`プリンシパルを使う意味

`arn:aws:iam::<ACCOUNT_ID>:root`をキーポリシーに記述することは、ルートユーザーだけがKMSを使えるという意味ではない。この典型的なStatementは、**同一AWSアカウントのIAMポリシーによるKMS権限付与を有効にする**ために使われる。

Plan用Roleには`kms:GenerateDataKey`、Apply用Roleには`kms:Decrypt`を付与した。実際のGitHub Actionsが最終的に成功したことから、今回の実行経路においてKMSによる生成・復号が機能したことを確認できた。

**補足：** IAM Policy Simulatorで`allowed`が出ても、それだけでKMS実操作成功を完全に証明するものではない。キーポリシー、SCP、Permissions Boundary、明示的なDenyなどを別途考慮する。

---

## 15. 1回目のGitHub Actions実行 — 変更なし・承認待ち・キャンセル

### 15.1 起動

2026年11月7日、次のコマンドで手動起動した。

```powershell
gh workflow run terraform-apply.yml --ref master
```

GitHubは`workflow_dispatch`イベントを受け付けた。

```text
Created workflow_dispatch event for terraform-apply.yml at master
```

実行ページ：[`Run 42334780238`](https://github.com/ryogayamamoto0117-tech/sprint1/actions/runs/42334780238)

### 15.2 Planジョブの結果

`gh run view 42334780238`で確認した結果：

```text
✓ Terraform Plan in 38s
* Terraform Apply

ARTIFACTS
terraform-plan
```

GitHub画面で以下のステップがすべて成功していた。

- `Configure AWS credentials for Plan`
- `Initialize Terraform with S3 backend`
- `Create Terraform Plan`
- `Check Terraform Plan Summary`
- `Encrypt Terraform Plan`
- `Verify Encrypted Plan Files`
- `Upload Terraform Plan`

Planログ：

```text
No changes. Your infrastructure matches the configuration.
```

これは**コード・State・AWS実態の比較の結果、AWSに反映すべき差分がなかった**ことを意味する。

### 15.3 Environmentの承認待ち

Workflow Summaryには以下が表示された。

```text
Status: Waiting
terraform-apply waiting for review
Review deployments
```

人間が承認しない限り、Applyジョブが実行されないことを確認した。

### 15.4 なぜキャンセルしたか

初回の目的は、Plan・暗号化・Artifact保存・承認ゲートまでの動作確認だった。変更がない状況でApply側まで実行する必要はないと判断し、**`Approve and deploy`は押さず、`Cancel workflow`をクリック**した。

画面には次の通知が出た。

```text
You have successfully requested the workflow to be canceled.
```

※ この通知は「キャンセル要求が受理された」という表示。最終ステータスの変化そのものは別途確認対象になるが、少なくともこの時点ではApply承認・実行をしていない。

### 15.5 初回実行で分かったこと

- OIDC → Plan用Role → S3 Backend → Terraform Planの経路が機能。
- KMSデータキー生成とAES-GCM暗号化が機能。
- Artifactのアップロードが機能。
- GitHub Environmentの人間による承認ゲートが機能。
- **まだApply側のOIDC、KMS復号、AWS更新は未検証**だった。

---

## 16. 2回目のGitHub Actions実行 — CloudWatch Logsの実更新

### 16.1 検証対象の選定

ECS/Fargateの新規起動やRDS変更は避け、影響範囲が小さく、実際にAWSへ更新されることを確かめられる設定を選んだ。

対象：

```text
CloudWatch Logs log group: /ecs/sprint6-app
Terraform resource: aws_cloudwatch_log_group.sprint6
File: infra/sprint6/main.tf
```

変更前：

```hcl
resource "aws_cloudwatch_log_group" "sprint6" {
  name              = "/ecs/sprint6-app"
  retention_in_days = 14
}
```

最初は15日への変更も考えたが、CloudWatch Logsの保持期間には指定可能な日数があり、**15日は対象外**。そこで、既存ログの保持期間を短縮しない**30日**を選択した。

変更後：

```hcl
resource "aws_cloudwatch_log_group" "sprint6" {
  name              = "/ecs/sprint6-app"
  retention_in_days = 30
}
```

### 16.2 Git差分の確認

```powershell
git diff -- infra/sprint6/main.tf
```

実際に確認した差分：

```diff
-  retention_in_days = 14
+  retention_in_days = 30
```

このときGitは`No newline at end of file`と表示していたため、VS Codeで最終行末に改行を追加した。

### 16.3 Gitへの反映

```powershell
git add infra/sprint6/main.tf
git diff --cached --check
git commit -m "test: update CloudWatch Logs retention from 14 to 30 days"
git push origin master
```

- `git add`：変更をステージング。
- `git diff --cached --check`：コミット候補の空白・末尾改行などを確認。
- `git commit -m`：意図した変更を履歴として確定。
- `git push origin master`：GitHubへ送信。

### 16.4 PushによりTerraform CIが自動起動

`infra/sprint6/main.tf`はTerraform CIの`paths`条件に一致するため、`terraform.yml`が自動起動した。

確認した実行：[`Terraform CI Run 42337948445`](https://github.com/ryogayamamoto0117-tech/sprint1/actions/runs/42337948445)

結果：**Success**。`fmt`、`init -backend=false`、`validate`、AWS OIDC認証、S3 Backend初期化、Planが成功した。

**重要：** GitHubへPushしてCIが成功しても、**この時点ではAWSリソースは更新されていない**。

### 16.5 Terraform Apply Workflowを手動起動

今回はGitHubのWeb画面で、`Terraform Apply`の`Run workflow`から`master`を指定して起動した。

実行ページ：[`Run 42338827283`](https://github.com/ryogayamamoto0117-tech/sprint1/actions/runs/42338827283)

### 16.6 Planで1件だけの更新を確認

`Create Terraform Plan`のログには以下が表示された。

```text
# aws_cloudwatch_log_group.sprint6 will be updated in-place
~ resource "aws_cloudwatch_log_group" "sprint6" {
    name              = "/ecs/sprint6-app"
  ~ retention_in_days = 14 -> 30
    # (8 unchanged attributes hidden)
  }

Plan: 0 to add, 1 to change, 0 to destroy.
Saved the plan to: tfplan
```

- **`update in-place`**：既存ロググループを削除・再作成せず属性を変更する。
- **`0 to add`**：新規作成なし。
- **`1 to change`**：更新対象1件。
- **`0 to destroy`**：削除対象なし。

Planで更新対象が`aws_cloudwatch_log_group.sprint6`の`retention_in_days`だけと確認したうえで承認へ進んだ。

### 16.7 Environmentで承認

GitHubのWorkflow Summaryに表示された`Review deployments`をクリックし、`terraform-apply`を選択して`Approve and deploy`を押した。

**承認ゲートを通ることでApplyジョブの実行が解放された。**

### 16.8 Applyジョブが成功

GitHub Actionsの最終結果：

| 項目 | 観測値 |
|---|---|
| Workflow | `Terraform Apply #2` |
| Run ID | `42338827283` |
| Planジョブ | 成功・36秒 |
| Applyジョブ | 成功・33秒 |
| Workflow全体 | **Success** |
| 総所要時間 | 2分27秒（承認待ちを含む画面表示） |
| Artifact | 1件 |

この成功から、Applyジョブでの**OIDC認証、Artifact取得、KMS復号、Terraformによる保存済みPlanのApply**が最後まで通ったことを確認できた。

### 16.9 AWS CLIで実際の設定を確認

最終的に、Terraformとは別のAWS CLIコマンドで、AWS実環境の保持期間を読み取った。

```powershell
aws logs describe-log-groups --log-group-name-prefix "/ecs/sprint6-app" --query "logGroups[?logGroupName=='/ecs/sprint6-app'].{Name:logGroupName,RetentionDays:retentionInDays}" --output table
```

**実測結果：**

```text
Name              RetentionDays
/ecs/sprint6-app   30
```

したがって、次の一連の因果関係を確認できた。

```text
main.tf の希望値：30日
    ↓ Git Commit / Push
Terraform CI：成功
    ↓ 手動起動
Terraform Plan：14日 → 30日を計画
    ↓ KMS暗号化 / Artifact
GitHub Environment：人間が承認
    ↓ KMS復号 / Apply
AWS CloudWatch Logs：実際に30日
```

### 16.10 Terraform Stateはどうなるか

今回の学習中に重要な疑問があった。

> 「main.tfを変更したということは、Stateを直接変えたということか？」

答えは**違う**。

| 時点 | `.tf`（希望） | State（管理上の記録） | AWS（実態） |
|---|---|---|---|
| 変更前 | 14日 | 14日 | 14日 |
| VS Codeで編集・Push後 | **30日** | 原則14日 | 14日 |
| Plan実行 | **30日** | 実態を参照して差分を評価 | 14日 |
| Apply成功後 | **30日** | **30日へ追随** | **30日** |

厳密にはPlan時のリフレッシュやState保存のタイミングに注意が必要だが、概念としては、**HCLがDesired State、Stateが管理情報、AWSがActual State**である。

TerraformはStateの情報を使って対象リソースを把握し、通常のPlanでAWSの実態を確認する。違いを計画として示し、ApplyでAWS APIによる変更とStateの更新を行う。

---

## 17. その他の警告・よくある疑問

### 17.1 GitHub ActionsのNode.js警告

Workflow実行時、以下の趣旨のAnnotationが表示された。

```text
Node.js 20 is deprecated.
Some actions target Node.js 20 but are being forced to run on Node.js 24.
```

`actions/checkout@v4`、`actions/setup-python@v5`、`actions/upload-artifact@v4`、`aws-actions/configure-aws-credentials@v4`、`hashicorp/setup-terraform@v3`等についての警告だった。今回のPlan・Applyの実行は成功したが、今後は各Actionの対応版を確認して更新する必要がある。

### 17.2 `ubuntu-latest`の変更通知

`ubuntu-latest`がUbuntu 26へ移行する趣旨の通知も表示された。これはただちに失敗を意味しないが、CIの再現性を重視するときはRunner OSの固定や互換性試験を検討する。

### 17.3 GitHub Actionsに表示される`*`の意味

`gh run view`で`* Terraform Apply`と表示されても、それだけで「実際にAWSへApply中」とは限らない。今回の初回テストではGitHubの画面で`Waiting`・`terraform-apply waiting for review`を確認し、**承認待ちで実処理が開始されていない**ことを区別できた。

### 17.4 `No changes`でも承認待ちになる

現在のWorkflowはPlan成功後にApplyジョブへ進む設計。Planに変更がなくても、`needs: plan`の条件だけでは自動スキップされない。変更0件のジョブは承認しない判断をした。

### 17.5 AWS CLIの認証主体に注意

ローカルPowerShellで使うAWS CLIと、GitHub ActionsがOIDCで引き受けるIAM Roleは別のプリンシパルになり得る。ローカルで`aws kms describe-key`が成功しても、Actions側のRoleに利用権限があるとは限らない。IAM Policy Simulatorと実行ログで分けて確認した。

---

## 18. 今回習得したコマンド・用語一覧

### 18.1 Terraform

| コマンド | 意味・用途 |
|---|---|
| `terraform init -migrate-state` | 既存Stateを新Backendへ移行する |
| `terraform init -reconfigure -input=false` | Backendを現在の設定で再初期化し、対話入力を無効化 |
| `terraform init -backend=false -input=false` | Backendを初期化せず構成検証の準備 |
| `terraform fmt -check -recursive` | HCLの書式を再帰的にチェック |
| `terraform validate` | Terraform構成の妥当性を検証 |
| `terraform state list` | Stateに登録された管理対象を一覧表示 |
| `terraform plan -input=false -out=tfplan` | 保存済みPlanを作成 |
| `terraform show -json tfplan` | 保存済みPlanをJSON形式で表示 |
| `terraform apply -input=false tfplan` | 事前に保存したPlanを適用 |

### 18.2 Git / GitHub CLI

| コマンド | 意味・用途 |
|---|---|
| `git status -sb` | 現在のブランチと差分の簡潔表示 |
| `git diff -- <path>` | 指定ファイルの未ステージング差分 |
| `git add <path>` | 変更をステージング |
| `git diff --cached --check` | ステージング済み差分の空白問題を検査 |
| `git commit -m "..."` | コミットメッセージを付けて履歴へ保存 |
| `git push origin master` | ローカルmasterをリモートへPush |
| `git show HEAD:<path>` | 現在のCommitに保存されたファイル内容を読む |
| `gh workflow list` | Workflow一覧 |
| `gh workflow run terraform-apply.yml --ref master` | 手動Workflowを起動 |
| `gh run view <RUN_ID>` | 指定実行の状況・ジョブを表示 |

### 18.3 AWS CLI

| コマンド | 意味・用途 |
|---|---|
| `aws sts get-caller-identity` | AWSの現在の認証主体を確認 |
| `aws iam get-role` | IAM RoleとTrust Policyを調べる |
| `aws iam list-attached-role-policies` | Roleにアタッチ済みの管理ポリシーを調べる |
| `aws iam get-policy` | ポリシーのデフォルトバージョン等を調べる |
| `aws iam get-policy-version` | ポリシー本文を取得 |
| `aws iam simulate-principal-policy` | 指定Action・Resourceに対するIAM権限をシミュレーション |
| `aws kms describe-key` | KMSキーの基本属性を確認 |
| `aws kms get-key-policy` | KMSキーポリシーを確認（今回はKey ID使用） |
| `aws logs describe-log-groups` | CloudWatch Logsの実際の保持期間を検証 |

### 18.4 重要用語

| 用語 | 理解したこと |
|---|---|
| IaC | インフラ構成をコードとして宣言・管理すること |
| Remote State | StateをローカルPCでなく共有ストレージ等で管理する方式 |
| State Lock | Stateの競合更新を防ぐ仕組み |
| Drift | HCLの期待値と実際のAWS設定のずれ |
| OIDC | GitHubなどのIdentity ProviderによるIDトークンで外部サービスと認証を連携する方式 |
| AWS STS | 一時的なAWS認証情報を発行するサービス |
| Trust Policy | 誰がRoleを引き受けられるかを定義 |
| Permissions Policy | Roleが何を操作できるかを定義 |
| `aud` / `sub` | OIDCトークンのAudience / Subject |
| Envelope Encryption | データキーで実データを暗号化し、データキーを別のキーで保護する方式 |
| AES-GCM | 暗号化と認証タグによる改ざん検出を組み合わせた方式 |
| Artifact | Workflowのジョブ間などで利用する保存成果物 |
| `workflow_dispatch` | GitHub Actionsの手動実行イベント |
| Environment | デプロイ保護ルールや環境単位の設定 |
| `update in-place` | リソースを置換せずに属性を更新すること |

---

## 19. セキュリティ・コスト・運用上の評価

### 19.1 今回できたこと

- S3 Stateの保存先をアプリ用Terraformと切り離した。
- StateバケットにVersioning・SSE-S3・公開ブロック・HTTPS制限を設定した。
- GitHubの長期AWSアクセスキーではなく、OIDCとSTSの一時認証を使用した。
- Plan用RoleとApply用Roleを分離した。
- Applyジョブの開始にGitHub Environmentの手動承認を要求した。
- Terraform Planのバイナリを暗号化してArtifactに保存した。
- 本番リソースの更新前にPlanをレビューした。
- 更新後、AWS CLIによって実際の値を確認した。

### 19.2 現状のまま本番用と断定しない理由

1. **IAM権限の全面監査が必要**：IAM管理権限を含むため、権限昇格・想定外リソース操作の経路を追加レビューする。
2. **GitHub ActionsのSupply Chain対策**：`uses: xxx@v4`等のメジャーバージョン指定から、コミットSHA固定やDependabot更新の運用を検討する。
3. **Plan情報の扱い**：Plan本文がログに出ること、Artifactのアクセス制御、秘密情報の混入にも注意する。
4. **手動承認の限界**：本人が本人の変更を承認できる設定であり、組織の独立レビューとは異なる。
5. **Stateの復旧訓練未実施**：Versioningがあっても復旧手順の検証は別途必要。
6. **Stateの並行操作試験未実施**：Lockfile設定とGitHub Concurrencyはあるが、競合操作の負荷試験までは確認していない。
7. **変更なしの自動スキップ未実装**：`No changes`でも承認待ちになる。
8. **PlanとApply間の運用**：長時間の承認待ちやState変更があった場合は、保存Planが古くなり適用できない可能性がある。
9. **料金の最終照合未実施**：S3、KMS、CloudWatch Logsなどの費用は使い方・保存量に応じて発生し得る。
10. **実環境の停止状態は別途確認**：今回のPlan対象はCloudWatch Logsのみ。Fargate、RDSの現在の稼働状態・AWS請求額をこのテストだけで証明したわけではない。

### 19.3 CloudWatch Logs保持期間とコスト

今回の変更は**14日から30日へ保持期間を延長**した。設定値の変更そのものは軽微で、ECSやRDSを新規起動する必要はなかった。一方、ログの保持が長くなるため、利用量次第では将来の保存コストが増える可能性がある。

**「変更作業に大きな料金がかからない」ことと「長期保存コストが増えない」ことは別。** 今回の実請求額は確認していない。

---

## 20. 完了チェックと今後の発展

### 20.1 Sprint 7で完了したこと

- [x] Sprint 6の既存Terraform構成を引き継いだ。
- [x] 既存StateをS3 Backendへ移行した。
- [x] Remote Stateで管理対象とPlanの整合性を確認した。
- [x] S3バケット保護設定を整えた。
- [x] `use_lockfile = true`を設定した。
- [x] GitHub Actions Terraform CIを作成し、成功を確認した。
- [x] GitHub OIDCでPlan用Roleを引き受けた。
- [x] AWS Providerの読み取り権限不足を修正した。
- [x] Apply用RoleとEnvironment承認ゲートを用意した。
- [x] PlanのKMS暗号化とArtifact受け渡しを実装した。
- [x] KMS権限の`implicitDeny`を調査・修正した。
- [x] Workflowの静的チェック、JSON構文チェック、Git除外を確認した。
- [x] `No changes`の初回試験で承認待ちまで確認した。
- [x] CloudWatch Logsの保持期間変更をGitHubへPushした。
- [x] 実際のPlanで更新1件・作成0・削除0を確認した。
- [x] 承認後にGitHub ActionsからApplyを成功させた。
- [x] AWS CLIで保持期間30日を確認した。

### 20.2 未実施・追加改善として残すこと

- [ ] 本書を`docs/sprint-7.md`へ配置し、現物のWorkflow・Terraformコードと整合させる。
- [ ] ドキュメントをGitへCommit・Pushする。
- [ ] 必要ならPRレビュー・マージを実施し、ローカル`master`との同期を確認する。
- [ ] 変更0件ならApplyジョブを自動スキップする。
- [ ] KMSキー・IAM権限・S3 Stateアクセスの最小権限を再監査する。
- [ ] Terraform Stateのバックアップ復元とLock競合検証を安全な方法で試す。
- [ ] GitHub Actionsのバージョン更新とActionのSHA固定を検討する。
- [ ] ワークフロー実行ログ・Artifactからの機密情報流出を点検する。
- [ ] CloudWatch Logsの保存量・S3/KMS/API利用料をCost Explorer等で確認する。
- [ ] ECS/Fargate・RDSの稼働状況と残存リソースを改めて棚卸しする。

### 20.3 次に発展させる場合の題材

今回のSprintで「コード化と変更制御」の土台ができた。次の題材としては、以下の方向へ拡張できる。

- **Terraform運用品質**：Planの差分をPRでレビューしやすくする、ドリフト検知、変更0件スキップ、State復旧。
- **DevOps / SRE**：ECSの更新・ロールバック、CloudWatchメトリクス・アラーム、障害対応演習、SLO/SLI。
- **Platform Engineering**：Module化、環境別変数・権限分離、再利用できるCI/CDテンプレート。
- **将来のAI基盤への接続**：Kubernetes/EKS、Observability、セキュリティ・コスト設計を学ぶ土台として活かす。

これは発展候補であり、Sprint 7で実装・検証した内容とは区別する。

---

## 21. 転職・ポートフォリオで説明できる実績

### 21.1 技術的な成果の表現例

> **個人開発のAWS環境に対して、TerraformのS3 Remote State化およびGitHub ActionsベースのCI/CDを構築。GitHub OIDCによる一時認証、Plan/ApplyのIAM Role分離、AWS KMSとAES-GCMによる保存済みTerraform Planの暗号化、GitHub Environmentを用いた手動承認を実装。CloudWatch Logsの保持期間を14日から30日へ変更し、Planの差分・Apply成功・AWS CLIによる実環境反映を確認した。**

### 21.2 面接で説明できるポイント

1. なぜローカルStateからS3 Backendへ移したか。StateとHCLとAWS実態の違い。
2. `terraform init -migrate-state`と`-reconfigure`の役割の違い。
3. なぜState LockとGitHubのConcurrencyの両方を使うのか。
4. 公開リポジトリのPRへ無条件にAWS権限を渡さない理由。
5. OIDCの`aud`・`sub`、STS、Trust PolicyとPermissions Policyの違い。
6. Plan用RoleとApply用Roleを分けた理由。
7. なぜTerraform Planを暗号化してArtifactへ渡す必要があったか。
8. `kms:GenerateDataKey`の`implicitDeny`をどう切り分けたか。
9. 変更0件と更新1件のPlanを、なぜ分けてレビューしたか。
10. 何をもって「Terraform Applyが成功した」と判断したか。GitHubの成功表示だけでなくAWS CLIでも確認した理由。

### 21.3 主な成果物への参照

- リポジトリ：<https://github.com/ryogayamamoto0117-tech/sprint1>
- Terraform CI：`.github/workflows/terraform.yml`
- Terraform Apply：`.github/workflows/terraform-apply.yml`
- Terraformコード：`infra/sprint6/`
- 暗号化・復号スクリプト：`scripts/encrypt_plan.py`、`scripts/decrypt_plan.py`
- IAMポリシー記録：`iam-policies/`
- 最初のWorkflow実行：<https://github.com/ryogayamamoto0117-tech/sprint1/actions/runs/42334780238>
- 保持期間変更後のCI：<https://github.com/ryogayamamoto0117-tech/sprint1/actions/runs/42337948445>
- **Apply成功の実行**：<https://github.com/ryogayamamoto0117-tech/sprint1/actions/runs/42338827283>

---

## 22. Sprint 7の総括

Sprint 6では、Terraformを使ってAWSリソースを作り、アプリケーションが実際に動くことを確認した。Sprint 7では、そのTerraformを**安全な変更管理の仕組み**として使えるようにした。

今回の学習の中心は、次の一連の流れだった。

```text
既存Stateの安全なS3移行
    ↓
State保護・Versioning・Lock
    ↓
GitHub ActionsのTerraform CI
    ↓
OIDC / IAMで安全にAWSへ接続
    ↓
Terraform Planで変更をレビュー
    ↓
保存PlanをKMS + AES-GCMで暗号化
    ↓
GitHub Environmentで人間が承認
    ↓
Apply用Roleで復号・Terraform Apply
    ↓
AWS CLIで変更の反映を確認
```

印象的だったのは、**KMSポリシーのResource ARNがたった1文字違うだけで`implicitDeny`になったこと**。問題を解くためには、エラー文を読み、IAM Role、アタッチ済みポリシー、バージョン、Action、Resource、キーポリシーを順番に調べる必要があった。

また、Terraform CIが成功してもAWSが変更されたとは限らず、Planの成功とApplyの成功も別、さらにApplyの成功と実際のAWS設定値の確認も別であると実感した。

最終的な証拠は明快だった。

```text
Terraformコードの保持期間        : 30日
Terraform Plan                   : 14 → 30日、変更1件
GitHub Actions Plan              : Success
GitHub Environment               : 人間が承認
GitHub Actions Apply             : Success
AWS CLIのRetentionDays実測値     : 30
```

**大きなAWSリソースを増やしたSprintではなかった。しかし、インフラを変更するまでの設計・認証・権限・暗号化・レビュー・実行・検証を一つにつなげたという意味で、DevOps / SRE / Platform Engineeringへ進むうえで重要なSprintとなった。**

### 最終チェック

- **技術目標：達成**
- **Remote State移行：成功**
- **Terraform CI：成功**
- **OIDC・IAM・KMS連携：実行結果で成功を確認**
- **PlanとApplyの権限・承認の分離：実装**
- **CloudWatch Logsの14日→30日変更：AWS実環境で確認済み**
- **本番相当のセキュリティ監査・復旧訓練：今後の課題**
- **本ドキュメントのGitHub保存：これから**

> この記録は学習と再現のための実践記録であり、そのまま本番環境へ適用する手順書ではない。公開前にAWSアカウントID、ARN、リソースID、ワークフロー、Secrets、State・PlanのGit追跡状況、IAM権限を必要に応じて再確認・匿名化すること。
