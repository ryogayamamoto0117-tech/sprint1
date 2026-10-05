# Spring Boot × AWS Learning Project

Java / Spring Boot / AWS / PostgreSQL / Linux / Docker / DevOpsを、  
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
- Container
- Container Registry
- Artifact Versioning
- Deploy / Rollback

まで、システム全体を段階的に構築・検証している。

---

## Tech Stack

### Application

- Java 17
- Spring Boot
- Maven
- PostgreSQL

### AWS

- Amazon EC2
- Amazon RDS
- Application Load Balancer
- Auto Scaling
- Amazon CloudWatch
- AWS Systems Manager
- Amazon S3
- Amazon ECR
- AWS IAM
- AWS Systems Manager Parameter Store
- AWS WAF

### DevOps / Container

- Docker
- Docker Compose
- GitHub Actions
- Git / GitHub
- Linux
- systemd

---

## Project Evolution

このプロジェクトでは、同じSpring Bootアプリケーションを段階的に発展させている。

```text
Sprint 1
Spring Boot
    ↓
EC2へ手動Deploy

Sprint 2
Spring Boot
    ↓
RDS PostgreSQL

Sprint 3
ALB
 ↓
Multi-AZ EC2
 ↓
systemd
 ↓
RDS

Sprint 3 Extension
Monitoring
 ↓
Auto Scaling
 ↓
Security
 ↓
CI/CD
 ↓
Rolling Deployment

Sprint 4
GitHub
 ↓
GitHub Actions
 ↓
Docker Image
 ↓
Amazon ECR
 ↓
EC2 Docker Host
 ↓
Container
 ↓
RDS
```

手動構築から始め、

```text
Manual Operation
      ↓
Automation
      ↓
CI/CD
      ↓
Containerization
      ↓
Container Orchestration
      ↓
Infrastructure as Code
```

へ段階的に発展させている。

---

## Sprint 3 Architecture

Sprint 3では、アプリケーション層をMulti-AZ構成にした。

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

> Sprint 3ではアプリケーション層を冗長化し、RDSはSingle-AZ構成で検証した。

---

## Sprint 4 Container Architecture

Sprint 4では、Spring BootアプリケーションをDocker Imageとして管理する構成へ移行した。

```text
Developer PC
      ↓
   git push
      ↓
    GitHub
      ↓
GitHub Actions
      ↓
Maven package
      ↓
Docker build
      ↓
Amazon ECR
      ↓
 docker pull
      ↓
EC2
      ↓
Docker Engine
      ↓
Spring Boot Container
      ↓
JDBC / PostgreSQL :5432
      ↓
RDS PostgreSQL
```

Sprint 3ではEC2へJARを直接配置していたが、Sprint 4では、

```text
Application
+
Runtime
+
Dependencies
+
Startup Command
```

をDocker ImageとしてArtifact化した。

---

## CI/CD Architecture - JAR Deployment

Sprint 3ではGitHub Actionsを利用し、  
コードのPushからEC2へのRolling Deploymentまでを自動化した。

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

## Container CI Architecture

Sprint 4では、GitHub ActionsからDocker ImageをBuildし、Amazon ECRへPushするPipelineを追加した。

```text
Source Code
      ↓
git commit
      ↓
git push
      ↓
GitHub Actions
      ↓
Maven package
      ↓
Docker build
      ↓
Docker Image
      ↓
Amazon ECR
```

Docker Image TagにはGit Commit SHAを利用する。

```yaml
IMAGE_TAG: ${{ github.sha }}
```

これにより、

```text
Git Commit
7cb0cad...

      ↓

Docker Image
sprint4-app:7cb0cad...
```

という形で、Source CodeとArtifactを追跡できる。

---

## Artifact Versioning

Sprint 4ではDocker ImageをVersionごとのArtifactとして管理した。

```text
Image A
0401d19b...

Image B
7cb0cad8...
```

それぞれの役割：

```text
Git Commit SHA
→ どのSource Codeか

Image Tag
→ どのVersionとして管理するか

Image Digest
→ Image Artifactの内容を識別する
```

EC2へPullしたImageとECR上のImageについて、Digestが一致することも確認した。

```text
ECR Artifact
      =
EC2へPullしたArtifact
```

TagだけではなくDigestまで確認することで、  
同一Artifactを使用していることを確認した。

---

## Docker Image / Container

Docker ImageとContainerを以下のように整理している。

```text
Docker Image
=
Containerを生成するためのArtifact

        ↓ docker run

Docker Container
=
Imageから生成された実行個体
```

Imageには主に、

```text
Java 17 Runtime
Spring Boot JAR
Java Libraries
Startup Command
```

を含める。

一方で、

```text
DB_HOST
DB_PORT
DB_NAME
DB_USER
DB_PASSWORD
```

などの環境依存情報はImageへ埋め込まず、Container起動時に外部から注入する。

```text
Image
  +
Configuration
  ↓
Container
```

---

## Configuration Externalization

Spring BootのDB接続設定を環境変数として外部化した。

```properties
spring.datasource.url=jdbc:postgresql://${DB_HOST}:${DB_PORT}/${DB_NAME}
spring.datasource.username=${DB_USER}
spring.datasource.password=${DB_PASSWORD}
spring.datasource.driver-class-name=org.postgresql.Driver
```

これにより、

```text
同じArtifact
    +
環境ごとのConfiguration
```

という構成が可能になった。

アプリケーションコードを変更せず、

```text
Development
Test
Production
```

などの環境差をConfigurationで吸収できる。

---

## Docker Compose

ローカルではDocker Composeを利用し、

```text
Spring Boot Container
        ↓
PostgreSQL Container
```

という構成を作成した。

```text
Docker Compose Network

app
 ↓
DB_HOST=db
 ↓
db
(PostgreSQL)
```

Compose内部ではService名をDNS名として利用できる。

PostgreSQLのデータにはNamed Volumeを使用した。

```text
PostgreSQL Container
        ↓
postgres_data
Named Volume
```

Containerを削除してもVolumeを削除しなければデータが維持されることを確認した。

---

## Container × RDS

AWS環境ではPostgreSQL Containerではなく、既存のAmazon RDS PostgreSQLへ接続した。

```text
EC2
 ↓
Docker Engine
 ↓
Spring Boot Container
 ↓
JDBC
 ↓
RDS PostgreSQL
```

Container起動時に、

```bash
-e DB_HOST="..."
-e DB_PORT="5432"
-e DB_NAME="sprint2db"
-e DB_USER="postgres"
-e DB_PASSWORD="$DB_PASSWORD"
```

としてConfigurationを注入する。

最後に指定するImageによって、どのApplication Versionを起動するかを決定する。

```text
docker run
   ↓
Container Configuration
   +
Docker Image
   ↓
Container
```

---

## Secret Management

DB PasswordはDocker Imageへ埋め込まず、  
AWS Systems Manager Parameter StoreのSecureStringとして管理した。

```text
/sprint3/db/password
```

EC2から、

```bash
aws ssm get-parameter
```

を利用して取得する。

構成：

```text
Parameter Store
      ↓
IAM Permission
      ↓
EC2
      ↓
Shell Variable
      ↓
docker run
      ↓
Container
```

Git RepositoryやDocker ImageへPasswordを保存しない構成とした。

---

## IAM Role / ECR Authentication

Sprint 4用EC2には専用IAM Roleを付与した。

```text
sprint4-docker-ec2-role
```

主な権限：

- Systems Manager接続
- ECR Read
- Parameter Store Read

Docker自身へIAM Roleを直接付与しているわけではない。

```text
EC2 IAM Role
      ↓
AWS CLI
      ↓
ECR Authentication Credential
      ↓
docker login
      ↓
Docker
      ↓
Amazon ECR
```

EC2のIAM Roleの権限を利用してECR用認証情報を取得し、  
Dockerへ渡すことでECRからImageをPullする。

ECR認証Tokenの期限切れも実際に経験した。

```text
Your authorization token has expired.
```

再度ECR Loginを行うことで復旧した。

この経験から、

```text
Authorization
=
IAM Roleによる認可

Authentication
=
DockerからECRへの認証
```

を区別して理解した。

---

## Rolling Deployment

Sprint 3では2台のEC2を同時に停止せず、  
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
EC2の性能ではなくTarget GroupのDeregistration Delayが主要な待機時間であることを確認した。

```text
Deregistration Delay
300 seconds = 5 minutes
```

Node-A / Node-Bそれぞれで約5分のDeregistration待機が発生しており、  
デプロイ時間の大部分が安全な接続終了のための待機時間であることを確認した。

---

## Container Deploy / Rollback

Sprint 4ではDocker Imageを利用したDeploy / Rollbackを実施した。

Version A：

```text
0401d19b...
Hello Sprint 3 CI/CD!
```

Version B：

```text
7cb0cad8...
Hello Sprint 4 Docker v2!
```

### Deploy

```text
Image A
  ↓
Container A
  ↓
Stop / Remove
  ↓
Image B
  ↓
Container B
```

確認：

```bash
curl http://localhost:8080/
```

結果：

```text
Hello Sprint 4 Docker v2!
```

Version BへのDeploy成功。

### Rollback

Container Bを停止・削除し、旧Image Aを指定して再生成した。

```text
Image B
  ↓
問題発生を想定
  ↓
Stop / Remove
  ↓
Image A
  ↓
Container再生成
```

確認：

```text
Hello Sprint 3 CI/CD!
```

ソースコードを書き戻したり、再Buildしたりせず、  
保存済みの旧ArtifactからContainerを再生成するだけでRollbackできた。

その後Version Bへ再Deployし、

```text
/health
→ OK

/
→ Hello Sprint 4 Docker v2!

/records
→ RDS接続成功
```

を確認した。

---

## Application / Data Lifecycle

Rollback時にContainerを削除・再生成しても、  
RDSに保存したデータは維持された。

```text
Application / Container
→ 交換可能

Data / RDS
→ 独立して永続化
```

Version Bで追加したRecordを、Version AへRollbackした後も取得できた。

これにより、

```text
Application Lifecycle
≠
Data Lifecycle
```

であることを確認した。

---

## Endpoints

- `GET /`
- `GET /health`
- `GET /instance`
- `GET /db-test`
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

また、DB接続だけを意図的に失敗させることで、

```text
/health  → 200 OK
/records → 500 Internal Server Error
```

という状態を作成した。

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

#### IAM / Parameter Store / S3

Auto ScalingやCI/CDで利用する権限をIAM Role / IAM Policyとして分離。

アプリケーションのJARはPrivate S3 Bucketへ配置し、  
DB PasswordはSystems Manager Parameter StoreのSecureStringとして管理。

User DataやGitHub Actionsへ認証情報を直接埋め込まない構成とした。

#### AWS WAF

Application Load BalancerへAWS WAFを関連付け、  
特定URIへのアクセスをBlockするルールを検証。

```text
/health   → 200 OK
/waf-test → 403 Forbidden
```

WAFによってALB到達前にHTTPリクエストを制御できることを確認した。

検証完了後、WAF Web ACLは削除。

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

### Sprint 4 - Docker × ECR × Container Deployment

Spring BootアプリケーションをDocker Image化し、  
Container ArtifactとしてBuild・保存・Deployする構成へ発展させた。

主な学習内容：

- Dockerfile
- Docker Image
- Docker Container
- Docker Layer
- Docker Compose
- Named Volume
- Container Network
- Configuration Externalization
- Secret Management
- Amazon ECR
- GitHub Actions Docker Build
- Image Tag
- Image Digest
- EC2 Docker Host
- IAM Role
- ECR Authentication
- Systems Manager Parameter Store
- Container → RDS接続
- Fault Injection
- Deploy
- Rollback
- Re-Deploy
- Data Persistence

Container実行環境では、

```text
Image
+
Configuration
=
Container
```

という構成を採用。

DB接続先を意図的に誤らせ、

```text
Container → Up
/health   → 200 OK
/records  → 500
```

という状態も作成した。

ログから、

```text
UnknownHostException
```

を特定し、

```text
Process Alive
≠
Service Ready
```

であることを確認した。

また、Git Commit SHAをImage Tagとして利用し、

```text
Source Code
↓
Git Commit SHA
↓
Docker Image Tag
↓
Amazon ECR
```

まで追跡できる構成とした。

最終的に、

```text
Version A
 ↓
Version B Deploy
 ↓
Version A Rollback
 ↓
Version B Re-Deploy
```

を実施。

Containerを削除・再生成してもRDSデータが維持されることを確認した。

[→ Sprint 4 詳細](docs/sprint-4.md)

---

## Troubleshooting Approach

障害発生時は、システムを層ごとに分けて確認する。

```text
Application
↓
Container
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
Container Up
/health 200
/records 500
```

の場合、

ContainerやSpring Boot Process自体は正常でも、  
Databaseなど外部依存先で障害が発生している可能性がある。

利用する情報：

- Application Log
- Docker Log
- HTTP Response
- Process Status
- Port
- Target Health
- CloudWatch Metrics
- AWS API
- IAM Identity

問題を、

```text
どのLayerで発生しているか
```

という観点で切り分ける。

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
Container Image
↓
Registry
↓
Server
↓
Container
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

単にAWSサービスやDocker Commandの使い方を覚えるのではなく、

```text
どのLayerで
何が起きていて
どのComponentが
何を担当しているのか
```

を理解することを目標とする。

特に、

```text
Code
↓
Git Commit
↓
Build
↓
Artifact
↓
Registry
↓
Deploy
↓
Runtime
↓
Data
```

のつながりを意識し、  
Application・OS・Network・Database・AWS Infrastructure・CI/CDを  
一連のSystemとして理解する。

---

## Next Step

Sprint 4では、Container Lifecycleを手動で操作した。

```text
docker pull
↓
docker stop
↓
docker rm
↓
docker run
↓
Health Check
↓
Rollback
```

次のSprintでは、このContainer LifecycleをAWSへ管理させる。

```text
Amazon ECR
    ↓
Amazon ECS
    ↓
Task Definition
    ↓
ECS Service
    ↓
Fargate / Container
```

これまで人間が行っていた、

```text
どのImageを動かすか
何個動かすか
障害時にどう再生成するか
どう更新するか
```

をContainer Orchestratorへ移していく。

その後、

```text
Infrastructure as Code
↓
Terraform
```

へ発展させ、AWS Infrastructureそのものの再現性・Version管理・自動化へ進む。