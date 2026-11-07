# Spring Boot × AWS | DevOps Learning Project

Java / Spring Bootで開発したWebアプリケーションを題材に、AWS上でのシステム構築から、可用性・監視・CI/CD・コンテナ運用・Infrastructure as Code（IaC）まで段階的に実装している学習プロジェクトです。

単にAWSサービスを利用するだけでなく、**アプリケーションの開発・デプロイ・運用を一つのシステムとして理解し、設計から構築・検証・改善まで実践すること**を目的としています。

## Current Status

**Sprint 7まで実装・検証済み。**

Sprint 6でTerraform管理したECS / Fargate環境を基盤に、Sprint 7では**Terraform StateのS3リモート管理と、GitHub Actionsによる承認付きTerraform CI/CD**を実装しました。

主な実装・検証内容：

- GitHub ActionsによるJavaアプリケーション・Dockerイメージのビルド
- Amazon ECRによるコンテナイメージ管理
- Amazon ECS / AWS Fargateによるコンテナ実行・管理
- ALBによるHTTPルーティングとヘルスチェック
- Amazon RDS PostgreSQLとのデータ連携
- CloudWatch Logsによるアプリケーションログ管理
- ECS Serviceによるタスクの自動再生成（Self Healing）
- **TerraformによるIAM・Security Group・ECS・ALB関連リソースのIaC化**
- **Terraform Planによる変更差分の確認、State管理、ドリフト検証**
- **ALB → Fargate → RDSのエンドツーエンド疎通確認（HTTP 200）**
- **Terraform StateのAmazon S3への移行（Versioning・暗号化・State Lock）**
- **GitHub ActionsによるTerraformの自動検証と、OIDCを使ったAWS認証**
- **Plan / Apply用IAM Roleの分離、KMSによるPlan暗号化、GitHub Environmentでの承認付きApply**
- **CloudWatch Logsの保持期間変更（14日 → 30日）をGitHub Actionsから適用し、AWS実環境で確認**

※ Sprint 6の検証終了時にはFargateタスクとRDSを停止しました。Sprint 7の最終検証ではCloudWatch Logsの設定を変更しており、Fargate / RDSの再起動は必要ありませんでした。既存ALB等のリソースには別途料金が発生する場合があります。

## Project Evolution

同じSpring Bootアプリケーションを継続的に発展させ、手動構築から自動化、コンテナ化、オーケストレーション、IaC、**安全なインフラ変更パイプライン**へと進んでいます。

| Sprint | テーマ | 実装・検証した内容 |
|---|---|---|
| **Sprint 1** | Spring Boot × EC2 | Linux上へのJARの手動デプロイ |
| **Sprint 2** | RDS PostgreSQL | DB接続、REST API、データ永続化 |
| **Sprint 3** | ALB × Multi-AZ EC2 | 負荷分散、冗長化、障害対応、Rolling Deployment |
| **Sprint 3 Extension** | Operations × CI/CD | CloudWatch、Auto Scaling、IAM、WAF、GitHub Actions |
| **Sprint 4** | Docker × Amazon ECR | コンテナ化、イメージ管理、デプロイ・ロールバック |
| **Sprint 5** | Amazon ECS × AWS Fargate | コンテナオーケストレーション、ALB連携、Self Healing、ログ管理 |
| **Sprint 6** | **Terraform × Infrastructure as Code** | **AWSリソースのコード管理、既存環境の再利用、ECS/Fargate構築、変更・ドリフト検証、アプリ疎通確認** |
| **Sprint 7** | **Terraform Remote State × GitHub Actions × OIDC / KMS** | **S3 State管理、Terraform CI、OIDC認証、Plan暗号化、承認付きApply、AWSへの変更反映を実証** |

### Architecture Evolution

```text
Sprint 1
Spring Boot → EC2
                 ↓
Sprint 2
Spring Boot → EC2 → RDS
                 ↓
Sprint 3
ALB → Multi-AZ EC2 → RDS
                 ↓
Sprint 3 Extension
Monitoring / Auto Scaling / CI/CD
                 ↓
Sprint 4
GitHub Actions → Docker → ECR
                           ↓
                      EC2 Container → RDS
                 ↓
Sprint 5
GitHub Actions → Docker → ECR
                           ↓
                      ECS / Fargate
                           ↓
                         ALB / RDS
                 ↓
Sprint 6
Terraform → Infrastructure as Code
                 ↓
IAM / SG / CloudWatch / ECS / ALB
                 ↓
ALB → ECS / Fargate → RDS
                 ↓
Sprint 7
Terraform State → Amazon S3 (Remote Backend / Lock)
                 ↓
GitHub Actions → Terraform Plan → KMS Encryption
                 ↓
          Environment Approval
                 ↓
        Decrypt → Terraform Apply → AWS
```

## Current Architecture — Sprint 7

Sprint 6のアプリケーション構成を維持しつつ、Sprint 7では**Terraformの状態管理と変更反映の経路**を拡張しました。

### Application Infrastructure（Sprint 6から継続）

```text
Developer PC → GitHub Actions → Docker Build → Amazon ECR
                                                 |
                                                 v
                                           ECS / Fargate
                                                 |
                                       Spring Boot Container
                                                 |
                           +---------------------+-------------------+
                           |                                         |
                     RDS PostgreSQL                           CloudWatch Logs

Client -- HTTP + X-Environment: sprint6 --> Existing ALB
                                               |
                                      Sprint 6 Listener Rule
                                               |
                                         Target Group
                                               |
                                       Fargate Task :8080
                                               |
                                        Spring Boot API
```

**既存VPC・ALB・RDSを再利用し、Sprint 6専用のIAM・Security Group・ECS・CloudWatch・ALB関連リソースをTerraformで管理しています。**

### Terraform CI/CD（Sprint 7で追加）

```text
Developer PC
    |
    | Edit .tf → Commit → Push (master)
    v
GitHub Repository
    |
    +--> Terraform CI (push / pull_request; path-filtered)
    |      └── fmt → init (-backend=false) → validate
    |          └── push時のAWS Plan（適用はしない）
    |
    +--> Terraform Apply Workflow (workflow_dispatch: 手動起動)
           |
           v
       Plan IAM Role <-- GitHub OIDC --> AWS STS
           |
           +--> S3 Remote State + Native State Lock
           |
           +--> terraform plan -out=tfplan
           |
           +--> AWS KMS Data Key → AES-GCM暗号化
           |
           +--> 暗号化PlanをGitHub Actions Artifactへ保存
           |
           v
       GitHub Environment: terraform-apply
           |
           | Required Reviewerによる手動承認
           v
       Apply IAM Role <-- GitHub OIDC --> AWS STS
           |
           +--> Artifact取得 → KMS復号 → Plan復号
           |
           +--> terraform apply tfplan
           v
       AWSリソース更新 + Terraform State更新（S3）
```

Terraform Stateは専用S3バケットに保存し、Versioning・サーバー側暗号化・パブリックアクセス遮断・HTTPS必須・`use_lockfile = true`を設定しています。PlanとApplyには別々のIAM Roleを使用し、**長期AWSアクセスキーをGitHub Actionsへ保存せずOIDCで一時認証**しています。

**Terraform Apply Workflowは手動起動・手動承認方式であり、Git PushだけでApplyが自動実行される構成ではありません。**

### Validation

#### Sprint 6 — Application / Infrastructure

| Verification | Result |
|---|---|
| Terraform Plan / Apply | Success |
| ECS Fargate Task | Running（検証時） |
| ALB Target Health | Healthy |
| `GET /health` | HTTP 200 OK |
| `GET /records` | HTTP 200 / PostgreSQLからJSONデータ取得 |
| Fargate停止 | Desired / Running / Pending = 0（検証終了時） |
| RDS停止 | stopped（検証終了時） |

#### Sprint 7 — Terraform CI/CD

| Verification | Result |
|---|---|
| S3 Remote State / State Lock | 移行・設定済み |
| Terraform CI（fmt / validate / Plan） | GitHub Actionsで成功 |
| GitHub OIDCによるAWS認証 | Plan / Apply双方で成功 |
| Planの暗号化・Artifact保存 | KMS + AES-GCMで成功 |
| GitHub Environmentの承認ゲート | 承認待ち・手動承認を確認 |
| 復号した保存済みPlanのApply | GitHub Actionsで成功 |
| CloudWatch Logs保持期間 | `14日 → 30日`、`0 add / 1 change / 0 destroy` |
| AWS実環境での確認 | `/ecs/sprint6-app` の `retentionInDays = 30` |

**Terraformコードの変更からAWS上の設定反映まで、GitHub Actions・OIDC・KMS・承認ゲートを介した一連の動作を検証しました。**

※ 今回の実証はCloudWatch Logsの小規模な設定変更です。複数人での本番運用、全リソースの再構築、あらゆる権限・障害条件の網羅検証までは行っていません。

## Tech Stack

| Category | Technologies |
|---|---|
| Application | Java 17, Spring Boot, Maven |
| Database | PostgreSQL, Amazon RDS |
| Infrastructure | AWS VPC, EC2, ALB, Auto Scaling |
| Infrastructure as Code | **Terraform, HCL, S3 Remote State, State Lock** |
| Container | Docker, Docker Compose, Amazon ECR |
| Orchestration | Amazon ECS, AWS Fargate |
| CI/CD | **GitHub Actions, Terraform CI / Plan / Apply, Git, GitHub** |
| Operations | Linux, systemd, AWS CLI, Amazon CloudWatch |
| Security | **AWS IAM, OIDC / AWS STS, AWS KMS, GitHub Environments**, Security Groups, Systems Manager Parameter Store, AWS WAF |
| Scripting | Python（Terraform Planの暗号化・復号） |

## Documentation

各Sprintの構築手順、AWS設定、設計判断、障害試験、トラブルシューティング、検証結果を記録しています。

- [Sprint 1 — Spring Boot × EC2](docs/sprint-1.md)
- [Sprint 2 — RDS PostgreSQL](docs/sprint-2.md)
- [Sprint 3 — ALB × Multi-AZ EC2 / Operations / CI/CD](docs/sprint-3.md)
- [Sprint 4 — Docker × ECR](docs/sprint-4.md)
- [Sprint 5 — ECS × Fargate](docs/sprint-5.md)
- [Sprint 6 — Terraform × Infrastructure as Code](docs/sprint-6.md)
- [**Sprint 7 — Terraform Remote State × GitHub Actions × OIDC / KMS**](docs/sprint-7.md)

## Next Step

**Cloud Infrastructure × Platform Engineering**

Sprint 7では、TerraformのRemote State運用と、レビュー・承認を挟んだAWS変更パイプラインを実装しました。

今後は、以下の領域を課題や興味に応じて深めていきます。

- Terraformモジュール化・環境分離・CI/CDの安全性向上
- Linux / AWSの障害調査、監視・可観測性（Observability）
- Kubernetes / Amazon EKS・コンテナ運用
- セキュリティ・可用性・コスト最適化

---

**Learning Goal**

アプリケーション・OS・ネットワーク・データベース・クラウドインフラ・CI/CD・IaC・運用を横断して理解し、**要件に基づく設計、構築、自動化、検証、障害対応まで一貫して判断できるクラウドエンジニア**を目指しています。
