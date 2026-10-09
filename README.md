# Spring Boot × AWS | DevOps Learning Project

Java / Spring Bootで開発したWebアプリケーションを題材に、AWS上でのシステム構築から、可用性・監視・CI/CD・コンテナ運用まで段階的に実装している学習プロジェクトです。

単にAWSサービスを利用するだけでなく、**アプリケーションの開発・デプロイ・運用を一つのシステムとして理解すること**を目的としています。

## Current Status

**Sprint 5まで実装・検証済み。**

現在は、DockerコンテナをAmazon ECS / AWS Fargateで実行し、Application Load Balancer経由でアクセスできる構成まで完成しています。

- GitHub ActionsによるJAR・Docker Imageのビルド
- Amazon ECRによるコンテナイメージ管理
- Amazon ECS / AWS Fargateによるコンテナ実行・管理
- ALBによるHTTPルーティングとヘルスチェック
- Amazon RDS PostgreSQLとのデータ連携
- Amazon CloudWatch Logsによるアプリケーションログの確認
- ECS Serviceによるタスクの自動再生成（Self Healing）

※ AWSリソースは学習時に起動し、不要な課金を抑えるため停止・縮退して管理しています。

## Project Evolution

同じSpring Bootアプリケーションを継続的に発展させ、手動構築から自動化、コンテナ化、オーケストレーションへ進んでいます。

| Sprint | テーマ | 実装・検証した内容 |
|---|---|---|
| **Sprint 1** | Spring Boot × EC2 | Linux上へのJARの手動デプロイ |
| **Sprint 2** | RDS PostgreSQL | DB接続、REST API、データ永続化 |
| **Sprint 3** | ALB × Multi-AZ EC2 | 負荷分散、冗長化、障害対応、Rolling Deployment |
| **Sprint 3 Extension** | Operations × CI/CD | CloudWatch、Auto Scaling、IAM、WAF、GitHub Actions |
| **Sprint 4** | Docker × Amazon ECR | コンテナ化、イメージ管理、デプロイ・ロールバック |
| **Sprint 5** | Amazon ECS × AWS Fargate | コンテナオーケストレーション、ALB連携、Self Healing、ログ管理 |

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
```

## Sprint 5 Architecture

現在到達している構成です。

```text
Developer PC
     |
  git push
     |
   GitHub
     |
GitHub Actions
     |
Docker Build
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
     +------> RDS PostgreSQL
     |
     +------> CloudWatch Logs


Client
   |
   v
Application Load Balancer
   |
   | X-Environment: sprint5
   v
Fargate Target Group
   |
   v
Fargate Task :8080
```

既存のALBを再利用し、HTTPヘッダーによってSprint 3のEC2構成とSprint 5のFargate構成を振り分けています。

ECS ServiceではDesired Countを指定してタスクを管理し、稼働中のタスクを停止させた際に、新しいタスクが自動的に起動することを確認しました。

※ Sprint 5ではFargateタスク1個で検証しており、複数タスクによる高可用性は未検証です。

## Tech Stack

| Category | Technologies |
|---|---|
| Application | Java 17, Spring Boot, Maven |
| Database | PostgreSQL, Amazon RDS |
| Infrastructure | AWS VPC, EC2, ALB, Auto Scaling |
| Container | Docker, Docker Compose, Amazon ECR |
| Orchestration | Amazon ECS, AWS Fargate |
| CI/CD | GitHub Actions, Git, GitHub |
| Operations | Linux, systemd, Amazon CloudWatch |
| Security | AWS IAM, Systems Manager Parameter Store, AWS WAF |

## Documentation

各Sprintの構築手順、AWS設定、障害試験、トラブルシューティング、設計判断は以下に記録しています。

- [Sprint 1 — Spring Boot × EC2](docs/sprint-1.md)
- [Sprint 2 — RDS PostgreSQL](docs/sprint-2.md)
- [Sprint 3 — ALB × Multi-AZ EC2 / Operations / CI/CD](docs/sprint-3.md)
- [Sprint 4 — Docker × ECR](docs/sprint-4.md)
- [Sprint 5 — ECS × Fargate](docs/sprint-5.md)

## Next Step

**Sprint 6 — Infrastructure as Code（IaC）**

これまでAWSマネジメントコンソールを中心に構築してきたインフラを、TerraformなどのIaCツールでコードとして定義・管理する予定です。

インフラの再現性、変更履歴の管理、環境構築の自動化を次の学習テーマとしています。

---

**Learning Goal**

アプリケーション・OS・ネットワーク・データベース・クラウドインフラ・CI/CD・運用を横断して理解し、設計から構築、障害対応まで一貫して判断できる技術力を身につけること。