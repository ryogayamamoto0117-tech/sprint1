# Spring Boot × AWS Learning Project

Java / Spring Boot / AWS / PostgreSQL / Linux / DevOpsを、  
1つのWebアプリケーションを育てながら学習するプロジェクト。

## Tech Stack

- Java 17
- Spring Boot
- Maven
- PostgreSQL
- AWS EC2
- AWS RDS
- AWS Application Load Balancer
- Linux
- systemd
- Git / GitHub

## Architecture

```text
Windows PC
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

## Endpoints

- `GET /`
- `GET /health`
- `GET /instance`
- `POST /records`
- `GET /records`

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

## Learning Goal

アプリケーションを段階的に育てながら、

```text
Code
↓
Build
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
Deployment
```

を横断して理解する。

単にAWSサービスの使い方を覚えるのではなく、  
「どの層で何が起きているのか」を切り分けながら、  
アプリケーション・OS・ネットワーク・データベース・AWSインフラを  
一連のシステムとして理解することを目標とする。