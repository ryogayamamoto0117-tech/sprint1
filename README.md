# Spring Boot × AWS Learning Project

Java / Spring Boot / AWS / PostgreSQL / Linux / DevOpsを、  
1つのWebアプリケーションを育てながら学習するプロジェクト。

アプリケーション開発だけでなく、

- Linux上でのプロセス管理
- AWSネットワーク
- データベース
- 可用性
- 監視
- Auto Scaling
- セキュリティ
- CI/CD
- Rolling Deployment

まで、システム全体を段階的に構築・検証している。

---

## Tech Stack

- Java 17
- Spring Boot
- Maven
- PostgreSQL
- AWS EC2
- AWS RDS
- AWS Application Load Balancer
- AWS Auto Scaling
- AWS CloudWatch
- AWS Systems Manager
- AWS S3
- AWS IAM
- AWS Systems Manager Parameter Store
- AWS WAF
- GitHub Actions
- Linux
- systemd
- Git / GitHub

---

## Architecture

現在のアプリケーション構成：

```text
Windows PC / Browser
        ↓ HTTP :80
Application Load Balancer
        ↓ HTTP :8080
        ├── EC2-A / Spring Boot / systemd
        │     ap-northeast-1a
        │
        └── EC2-B / Spring Boot / systemd
              ap-northeast-1c
                    ↓
            JDBC / PostgreSQL :5432
                    ↓
              RDS PostgreSQL
```

EC2を異なるAvailability Zoneへ配置し、  
Application Load Balancer経由で2台のSpring Bootアプリケーションへリクエストを分散する。

2台のEC2は同じRDS PostgreSQLを利用する。

> 現在はアプリケーション層を冗長化しており、RDSはSingle-AZ構成。

---

## CI/CD Architecture

GitHub Actionsを利用し、  
コードのPushからEC2へのRolling Deploymentまでを自動化している。

```text
Source Code
    ↓
git push
    ↓
GitHub
    ↓
GitHub Actions
    ↓
Maven Build
    ↓
JAR
    ↓
Amazon S3
    ↓
AWS Systems Manager
    ↓
EC2-B Deploy
    ↓
EC2-A Deploy
```

GitHub ActionsからAWSへの認証には  
OpenID Connect（OIDC）を利用する。

```text
GitHub Actions
      ↓
     OIDC
      ↓
AWS STS
      ↓
IAM Role
      ↓
AWS API
```

長期Access KeyをGitHubへ保存せず、  
一時的なAWS認証情報を利用してデプロイする構成としている。

---

## Rolling Deployment

2台のEC2を同時に停止せず、  
1台ずつ更新するRolling DeploymentをGitHub Actionsで自動化した。

```text
Maven Build
    ↓
JAR → S3
    ↓
Node-B Deregister
    ↓
Deregistration完了待機
    ↓
Node-B Deploy
    ↓
systemd restart
    ↓
/health確認
    ↓
Node-B Register
    ↓
ALB Healthy確認
    ↓
Node-A Deregister
    ↓
Deregistration完了待機
    ↓
Node-A Deploy
    ↓
systemd restart
    ↓
/health確認
    ↓
Node-A Register
    ↓
ALB Healthy確認
```

Node-BがALB上でHealthyに復帰してからNode-Aの更新を開始することで、  
デプロイ中も最低1台のEC2がサービスを提供できる構成とした。

初回の自動Rolling Deploymentは約11分55秒で完了した。

処理時間を分析した結果、  
EC2の性能ではなく、Target GroupのDeregistration Delayが主要な待機時間であることを確認した。

```text
Deregistration Delay
300 seconds = 5 minutes
```

Node-A / Node-Bそれぞれで約5分のDeregistration待機が発生しており、  
デプロイ時間の大部分が安全な接続終了のための待機時間であることを確認した。

---

## Endpoints

- `GET /`
- `GET /health`
- `GET /instance`
- `POST /records`
- `GET /records`

---

## Learning Sprints

### Sprint 1 - Spring Boot × EC2

Spring BootアプリケーションをEC2へ手動デプロイ。

主な学習内容：

- Maven / JAR
- AWS VPC / Subnet / Security Group
- EC2 / Linux
- Process / Port / HTTP
- SSH / SCP
- 障害切り分け

[→ Sprint 1 詳細](docs/sprint-1.md)

---

### Sprint 2 - Spring Boot × RDS PostgreSQL

Spring BootからRDS PostgreSQLへ接続し、  
学習記録を保存・取得するAPIを構築。

主な学習内容：

- PostgreSQL / SQL
- JDBC
- POST / GET API
- JSON / Java Object
- Persistence
- DB Network / Security Group
- Authentication
- Manual Deployment
- Troubleshooting
- RDS vs Aurora

[→ Sprint 2 詳細](docs/sprint-2.md)

---

### Sprint 3 - ALB × Multi-AZ EC2 × systemd

EC2を異なるAvailability Zoneへ2台配置し、  
Application Load Balancer経由でSpring Bootアプリケーションを冗長化。

systemdによるアプリケーション管理、障害試験、  
Rolling Deployment / Rollbackまで実施。

主な学習内容：

- Application Load Balancer
- Target Group
- Multi-AZ EC2
- Security Group間通信
- systemd
- Health Check
- Load Balancing
- Failover
- Liveness / Readiness
- DB依存障害の観測
- Rolling Deployment
- Rollback
- Troubleshooting

障害試験では、片方のEC2上のアプリケーションを停止し、  
ALBが正常なEC2へリクエストを送り続けることを確認。

また、DB接続だけを意図的に失敗させることで、次の状態を作成した。

```text
/health  → 200 OK
/records → 500 Internal Server Error
```

これにより、単純なHealth Checkでは、  
アプリケーションの依存先障害を検知できない場合があることを確認した。

[→ Sprint 3 詳細](docs/sprint-3.md)

---

### Sprint 3 Extension - Operations / Scaling / Security / CI/CD

Sprint 3で構築した冗長構成をベースに、  
実運用を意識した監視・Auto Scaling・セキュリティ・CI/CDまで拡張した。

#### CloudWatch

Application Load Balancer / EC2のメトリクスをCloudWatchで観測。

確認した主なメトリクス：

- HealthyHostCount
- RequestCount
- CPUUtilization

CPUUtilizationに対してCloudWatch Alarmを作成し、  
SNS経由でメール通知を受信する構成を作成。

EC2へCPU負荷を発生させ、  
実際にAlarm状態へ遷移することを確認した。

---

#### Auto Scaling

Launch TemplateとAuto Scaling Groupを構築。

EC2起動時のUser Dataによって、

```text
EC2起動
 ↓
Java Install
 ↓
S3からJAR取得
 ↓
Parameter StoreからDB Password取得
 ↓
systemd設定
 ↓
Spring Boot起動
```

まで自動化した。

アプリケーション停止によってTargetがUnhealthyになった際、  
Auto Scaling GroupがEC2を置き換えるSelf Healingも確認。

Target Tracking Scaling Policyを利用し、  
CPU負荷に応じてEC2台数が増減することも確認した。

---

#### IAM / Parameter Store / S3

Auto ScalingやCI/CDで利用する権限をIAM Role / IAM Policyとして分離。

アプリケーションのJARはPrivate S3 Bucketへ配置し、  
DB PasswordはSystems Manager Parameter StoreのSecureStringとして管理。

User DataやGitHub Actionsへ認証情報を直接埋め込まない構成とした。

---

#### AWS WAF

Application Load BalancerへAWS WAFを関連付け、  
特定URIへのアクセスをBlockするルールを検証。

```text
/health   → 200 OK
/waf-test → 403 Forbidden
```

WAFによってALB到達前にHTTPリクエストを制御できることを確認した。

検証完了後、WAF Web ACLは削除。

---

#### GitHub Actions CI

GitHubへのPushをトリガーとして、  
GitHub Actions上で自動Buildを行うCI Pipelineを構築。

```text
git push
 ↓
GitHub Actions
 ↓
Checkout
 ↓
Java 17 Setup
 ↓
Maven Build
 ↓
JAR
 ↓
GitHub Artifact
```

Maven Wrapperの実行権限問題などもトラブルシューティングし、  
CI環境上でSpring Boot JARを生成できることを確認した。

---

#### GitHub Actions CD

GitHub ActionsからAWSへOIDCで認証し、  
S3 / Systems Manager / Application Load Balancerを操作するCD Pipelineを構築。

```text
GitHub Actions
 ↓
OIDC
 ↓
AWS STS
 ↓
IAM Role
 ↓
S3
 ↓
Systems Manager
 ↓
EC2
```

EC2へのデプロイではSSH / SCPを使用せず、  
AWS Systems Manager Run Commandを利用。

EC2上では次の処理を自動実行する。

```text
既存JAR Backup
 ↓
S3から新JAR取得
 ↓
JAR置換
 ↓
systemctl restart
 ↓
systemctl is-active
 ↓
curl /health
```

最終的に、

```text
git push
 ↓
Build
 ↓
JAR
 ↓
S3
 ↓
Rolling Deployment
 ↓
ALB Healthy確認
```

までを自動化した。

---

## Troubleshooting Approach

障害発生時は、システムを層ごとに分けて確認する。

```text
Application
↓
Process
↓
Port
↓
OS
↓
Network
↓
Load Balancer
↓
Database
↓
AWS Service
```

例えば、

```text
ALB Healthy
/health 200
/records 500
```

の場合、

ALBやSpring Bootプロセス自体は正常でも、  
Databaseなど外部依存先で障害が発生している可能性がある。

ログ、HTTPレスポンス、Target Health、CloudWatch Metricsなどを利用し、  
どの層で問題が発生しているかを切り分ける。

---

## Learning Goal

アプリケーションを段階的に育てながら、

```text
Code
↓
Build
↓
Artifact
↓
Server
↓
Process
↓
Port
↓
HTTP
↓
Network
↓
Database
↓
Load Balancing
↓
Availability
↓
Monitoring
↓
Scaling
↓
Security
↓
CI
↓
CD
↓
Operations
```

を横断して理解する。

単にAWSサービスの使い方を覚えるのではなく、  
「どの層で何が起きているのか」を切り分けながら、  
アプリケーション・OS・ネットワーク・データベース・AWSインフラ・CI/CDを  
一連のシステムとして理解することを目標とする。

また、手作業で構築・運用した内容を段階的に自動化し、

```text
Manual Operation
      ↓
Automation
      ↓
CI/CD
      ↓
Infrastructure as Code
```

へ発展させていく。

次のSprintでは、Terraformを利用したInfrastructure as Codeへ進む。