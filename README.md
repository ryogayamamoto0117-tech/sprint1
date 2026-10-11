# Spring Boot × AWS | DevOps Learning Project

Java / Spring Bootで開発したWebアプリケーションを題材に、AWS上でのシステム構築から、可用性・監視・CI/CD・コンテナ運用・Infrastructure as Code（IaC）まで段階的に実装している学習プロジェクトです。

単にAWSサービスを利用するだけでなく、**アプリケーションの開発・デプロイ・運用を一つのシステムとして理解し、設計から構築・検証・改善まで実践すること**を目的としています。

## Current Status

**Sprint 6まで実装・検証済み。**

Amazon ECS / AWS Fargateで動作するSpring Bootアプリケーションを、Terraformによって定義・構築・管理できる構成まで発展させました。

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

※ 学習環境のため、FargateタスクとRDSは検証後に停止しています。既存ALBなどのリソースは引き続き存在します。

## Project Evolution

同じSpring Bootアプリケーションを継続的に発展させ、手動構築から自動化、コンテナ化、オーケストレーション、IaCへと進んでいます。

| Sprint | テーマ | 実装・検証した内容 |
|---|---|---|
| **Sprint 1** | Spring Boot × EC2 | Linux上へのJARの手動デプロイ |
| **Sprint 2** | RDS PostgreSQL | DB接続、REST API、データ永続化 |
| **Sprint 3** | ALB × Multi-AZ EC2 | 負荷分散、冗長化、障害対応、Rolling Deployment |
| **Sprint 3 Extension** | Operations × CI/CD | CloudWatch、Auto Scaling、IAM、WAF、GitHub Actions |
| **Sprint 4** | Docker × Amazon ECR | コンテナ化、イメージ管理、デプロイ・ロールバック |
| **Sprint 5** | Amazon ECS × AWS Fargate | コンテナオーケストレーション、ALB連携、Self Healing、ログ管理 |
| **Sprint 6** | **Terraform × Infrastructure as Code** | **AWSリソースのコード管理、既存環境の再利用、ECS/Fargate構築、変更・ドリフト検証、アプリ疎通確認** |

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
```

## Current Architecture — Sprint 6

Sprint 6では、Sprint 5までの構成を再利用しながら、Terraformによるインフラ管理を導入しました。

```text
                  Developer PC
                       |
                    git push
                       |
                     GitHub
                       |
                 GitHub Actions
                       |
               Docker Image Build
                       |
                   Amazon ECR
                       |
                       | Container Image
                       v
               Amazon ECS Service
                       |
                 AWS Fargate Task
                       |
               Spring Boot Container
                       |
                       +--------> RDS PostgreSQL
                       |
                       +--------> CloudWatch Logs


Client
   |
   | HTTP + X-Environment: sprint6
   v
Existing Application Load Balancer
   |
   v
Sprint 6 Listener Rule
   |
   v
Sprint 6 Target Group
   |
   v
Fargate Task :8080
   |
   v
Spring Boot REST API


Terraform
   |
   +-- CloudWatch Log Group
   +-- Security Group / Ingress / Egress
   +-- IAM Execution Role / Policies
   +-- ECS Task Definition
   +-- ECS Cluster / Service
   +-- ALB Target Group / Listener Rule
   |
   +-- Data Sources
       +-- Existing VPC / Subnets
       +-- Existing ALB Listener
       +-- Existing Security Groups
```

**既存VPC・ALB・RDSを再利用し、Sprint 6専用のECS環境と関連リソースをTerraformで管理しています。**

Terraformによる新規構築と、Data Sourceによる既存リソースの参照を使い分け、既存のSprint環境を維持したまま構成を拡張しました。

### Sprint 6 Validation

実際のAWS環境で以下を確認しています。

| Verification | Result |
|---|---|
| Terraform Plan / Apply | Success |
| ECS Fargate Task | Running |
| ALB Target Health | Healthy |
| `GET /health` | HTTP 200 OK |
| `GET /records` | HTTP 200 / PostgreSQLからJSONデータ取得 |
| Fargate停止 | Desired / Running / Pending = 0 |
| RDS停止 | stopped |

**Terraformによるインフラ構築から、コンテナ起動、ALB経由のHTTP通信、RDSとのデータ連携まで一連の動作を検証しました。**

※ Sprint 6ではFargateタスク1個で検証しています。複数タスクの可用性やAuto Scalingは今回の検証対象外です。

## Tech Stack

| Category | Technologies |
|---|---|
| Application | Java 17, Spring Boot, Maven |
| Database | PostgreSQL, Amazon RDS |
| Infrastructure | AWS VPC, EC2, ALB, Auto Scaling |
| Infrastructure as Code | **Terraform, HCL, Terraform State** |
| Container | Docker, Docker Compose, Amazon ECR |
| Orchestration | Amazon ECS, AWS Fargate |
| CI/CD | GitHub Actions, Git, GitHub |
| Operations | Linux, systemd, AWS CLI, Amazon CloudWatch |
| Security | AWS IAM, Security Groups, Systems Manager Parameter Store, AWS WAF |

## Documentation

各Sprintの構築手順、AWS設定、設計判断、障害試験、トラブルシューティング、検証結果を記録しています。

- [Sprint 1 — Spring Boot × EC2](docs/sprint-1.md)
- [Sprint 2 — RDS PostgreSQL](docs/sprint-2.md)
- [Sprint 3 — ALB × Multi-AZ EC2 / Operations / CI/CD](docs/sprint-3.md)
- [Sprint 4 — Docker × ECR](docs/sprint-4.md)
- [Sprint 5 — ECS × Fargate](docs/sprint-5.md)
- [**Sprint 6 — Terraform × Infrastructure as Code**](docs/sprint-6.md)

## Next Step

**Infrastructure Automation & Cloud Architecture**

Sprint 6では、Terraformによるリソース定義・差分確認・構築・検証の基本ワークフローを実践しました。

今後は以下の領域へ発展させていく予定です。

- TerraformのリモートState管理・運用改善
- IaCのCI/CD連携と自動検証
- AWSアーキテクチャのセキュリティ・可用性・コスト最適化
- コンテナ運用・監視・デプロイのさらなる自動化

※ 現時点ではTerraformの実行はローカル環境から行っており、TerraformによるCI/CDデプロイは未実装です。

---

**Learning Goal**

アプリケーション・OS・ネットワーク・データベース・クラウドインフラ・CI/CD・IaC・運用を横断して理解し、**要件に基づく設計、構築、自動化、検証、障害対応まで一貫して判断できるクラウドエンジニア**を目指しています。