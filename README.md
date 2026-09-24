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
- Linux
- Git / GitHub

## Architecture

```text
Windows PC
    ↓ HTTP :8080
EC2 / Spring Boot
    ↓ JDBC / PostgreSQL :5432
RDS PostgreSQL
```

## Endpoints

- `GET /`
- `GET /health`
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
Deployment
```

を横断して理解する。