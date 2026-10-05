# Sprint 4 - Docker / ECR / Container Deployment

## 1. Sprint 4 Goal

Sprint 4では、Sprint 3までEC2上へ直接配置していたSpring BootアプリケーションをDocker Containerとして実行できるようにする。

また、Docker ImageをArtifactとして管理し、GitHub ActionsからAmazon ECRへ保存、EC2上のDockerへDeployする一連の流れを構築する。

最終的には以下を経験することを目標とした。

- Spring BootのConfiguration外部化
- Docker Imageの作成
- Docker Containerの起動
- Docker ComposeによるアプリケーションとPostgreSQLの構築
- Secretの外部管理
- Health Checkと障害観測
- GitHub ActionsによるDocker Image Build
- Amazon ECRへのImage Push
- EC2からECR ImageをPull
- Docker ContainerからRDS PostgreSQLへ接続
- Image Tag / DigestによるArtifact管理
- Image更新
- Deploy
- Rollback

---

## 2. Architecture

Sprint 4の最終構成は以下。

```text
Developer PC
    |
    | git push
    v
GitHub
    |
    v
GitHub Actions
    |
    | Maven package
    | Docker build
    v
Docker Image
    |
    | docker push
    v
Amazon ECR
    |
    | docker pull
    v
EC2
    |
    v
Docker Engine
    |
    v
Spring Boot Container
    |
    | JDBC
    v
Amazon RDS PostgreSQL
```

GitHub ActionsでDocker Imageを作成し、ECRへArtifactとして保存する。

EC2上ではECRからImageを取得し、外部Configurationを渡してContainerを生成する。

---

# 3. Phase 1 - Configuration Externalization

Spring BootのDB接続情報をソースコードに固定せず、環境変数から取得できるようにした。

`application.properties`

```properties
spring.application.name=sprint1

spring.datasource.url=jdbc:postgresql://${DB_HOST}:${DB_PORT}/${DB_NAME}
spring.datasource.username=${DB_USER}
spring.datasource.password=${DB_PASSWORD}
spring.datasource.driver-class-name=org.postgresql.Driver
```

以下を外部Configurationとして扱う。

- `DB_HOST`
- `DB_PORT`
- `DB_NAME`
- `DB_USER`
- `DB_PASSWORD`

これにより、Docker Image自体を変更せず、環境ごとに異なるConfigurationを注入できるようになった。

```text
共通Artifact
      +
環境ごとのConfiguration
      ↓
実行環境
```

---

# 4. Phase 2 - Docker

Spring BootアプリケーションをDocker Image化した。

`Dockerfile`

```dockerfile
FROM eclipse-temurin:17-jre

COPY target/sprint1-0.0.1-SNAPSHOT.jar app.jar

ENTRYPOINT ["java", "-jar", "app.jar"]
```

Imageには主に以下が含まれる。

```text
Docker Image

├─ Java 17 Runtime
├─ Spring Boot JAR
├─ Java Libraries
└─ 起動方法
   java -jar app.jar
```

Docker ImageからContainerを生成することで、同一Artifactを繰り返し実行できる。

```text
Image
  |
  +--> Container A
  |
  +--> Container B
  |
  +--> Container C
```

Containerは実行個体であり、Imageはその元となるArtifactである。

---

# 5. Phase 3 - Docker Compose

ローカル環境ではDocker Composeを使用し、

- Spring Boot
- PostgreSQL

をContainerとして起動した。

構成イメージ：

```text
Docker Compose

app
 |
 | DB_HOST=db
 v
db
(PostgreSQL)
```

Compose内部ではService名をDNS名として利用できるため、

```text
DB_HOST=db
```

としてSpring Boot ContainerからPostgreSQL Containerへ接続した。

PostgreSQLデータはNamed Volumeを使用して永続化した。

```text
PostgreSQL Container
        |
        v
postgres_data
Named Volume
```

そのためContainerを削除・再作成しても、DBデータはVolumeに残る構成となった。

---

# 6. Phase 4 - Secret / Health / Fault Injection

## Secret管理

DB PasswordをDocker Imageへ埋め込まず、外部から渡す構成とした。

ローカルでは`.env`を使用。

`.env`はGit管理対象外とした。

```text
.env
↓
Docker Compose
↓
Container Environment Variable
```

AWS環境ではAWS Systems Manager Parameter Storeを利用。

Parameter：

```text
/sprint3/db/password
```

種類：

```text
SecureString
```

EC2から以下で取得した。

```bash
DB_PASSWORD=$(aws ssm get-parameter \
  --name "/sprint3/db/password" \
  --with-decryption \
  --query "Parameter.Value" \
  --output text)
```

Secretの値そのものは画面へ表示しない。

---

## Health Check

Spring Bootには以下のEndpointが存在する。

```text
/health
/records
```

`/health`

```text
Spring Boot Processが起動しているか
```

`/records`

```text
Spring Boot
↓
JDBC
↓
PostgreSQL
```

まで正常か確認できる。

---

## Fault Injection

意図的に、

```text
DB_HOST=wrong-db-host
```

としてContainerを起動した。

結果：

```text
/health
→ OK

/records
→ HTTP 500
```

Docker Container自体は稼働していた。

```bash
docker ps
```

では`Up`。

しかしログでは、

```text
java.net.UnknownHostException: wrong-db-host
```

を確認した。

つまり、

```text
Processが生きている
≠
Service全体が正常
```

であることを確認した。

これは今後の、

- Liveness Probe
- Readiness Probe
- ECS Health Check
- Kubernetes Health Check

につながる考え方。

---

# 7. Phase 5 - GitHub Actions → Amazon ECR

Amazon ECRにPrivate Repositoryを作成。

Repository：

```text
sprint4-app
```

Region：

```text
ap-northeast-1
```

GitHub ActionsからDocker ImageをBuildし、ECRへPushするWorkflowを作成した。

Workflow：

```text
.github/workflows/container-build.yml
```

処理：

```text
git push
   ↓
GitHub Actions
   ↓
Checkout
   ↓
Java 17 Setup
   ↓
Maven package
   ↓
AWS OIDC Authentication
   ↓
ECR Login
   ↓
docker build
   ↓
docker push
```

GitHub ActionsからAWSへはOIDCを使用。

長期Access KeyはGitHubへ保存しない。

---

## Image Tag

Docker Image TagにはGit Commit SHAを使用。

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

という形で、

```text
Source Code
↕
Docker Artifact
```

を追跡できる。

---

# 8. Phase 6 - ECR → EC2 → Docker → RDS

新しいEC2をDocker実行環境として作成。

EC2：

```text
Name:
sprint4-docker

Instance ID:
i-010fe232703c73725

Instance Type:
t3.micro

OS:
Amazon Linux 2023
```

SSHは使用せず、AWS Systems Manager Session Managerから接続した。

Security Groupには通常のInbound接続を追加していない。

---

## IAM Role

EC2には以下のIAM Roleを付与。

```text
sprint4-docker-ec2-role
```

主なPermission：

```text
AmazonSSMManagedInstanceCore
CloudWatchAgentServerPolicy
AmazonEC2ContainerRegistryReadOnly
```

またParameter StoreのDB Password取得用に、

```text
ssm:GetParameter
```

を許可。

---

## Docker Install

Amazon Linux 2023へDockerをインストール。

```bash
sudo dnf install -y docker
```

起動・自動起動：

```bash
sudo systemctl enable --now docker
```

---

## IAM Role確認

以下でEC2がどのIAM IdentityとしてAWSへアクセスしているか確認した。

```bash
aws sts get-caller-identity
```

結果：

```text
assumed-role/sprint4-docker-ec2-role/...
```

EC2がIAM RoleをAssumeしてAWS APIへアクセスしていることを確認した。

---

## ECR Authentication

Docker自身はIAM Roleを直接理解しない。

そのため、

```text
EC2 IAM Role
     ↓
AWS CLI
     ↓
ECR用認証情報取得
     ↓
docker login
     ↓
Docker
     ↓
ECR
```

という流れで認証する。

実行：

```bash
aws ecr get-login-password --region ap-northeast-1 | \
sudo docker login \
  --username AWS \
  --password-stdin \
  237575223564.dkr.ecr.ap-northeast-1.amazonaws.com
```

---

## Docker Pull

ECRからImageを取得。

```bash
sudo docker pull \
237575223564.dkr.ecr.ap-northeast-1.amazonaws.com/sprint4-app:<IMAGE_TAG>
```

ImageはLayer単位で管理される。

新しいImageをPullした際、

```text
Already exists
```

となったLayerは再利用され、

変更されたLayerのみ、

```text
Pull complete
```

となった。

---

# 9. Image Tag / Digest

Docker ImageにはTagとDigestが存在する。

## Tag

```text
7cb0cad8...
```

今回の構成ではGit Commit SHAを使用。

目的：

```text
どのVersionか
どのGit Commitから作られたか
```

を追跡する。

---

## Digest

例：

```text
sha256:7ec9a570a2d3fcf3196616252c8298dd654f635222b1b51170edec59a64badf2
```

DigestはImage Artifactの内容を識別する。

ECR側のDigestとEC2側のRepoDigestが一致することを確認した。

これにより、

```text
ECRに保存されているArtifact
=
EC2が取得したArtifact
```

であることを確認できる。

整理すると、

```text
Git Commit SHA
→ どのSource Codeか

Image Tag
→ どのVersionとして管理しているか

Image Digest
→ Artifactの内容そのものを識別
```

---

# 10. EC2 Docker → RDS

Docker Containerから既存のRDS PostgreSQLへ接続した。

RDS：

```text
sprint2-postgres
```

Endpoint：

```text
sprint2-postgres.c7y2kowyu6ih.ap-northeast-1.rds.amazonaws.com
```

Port：

```text
5432
```

DB：

```text
sprint2db
```

User：

```text
postgres
```

RDS Security Groupでは、

```text
Source:
sprint4-docker-sg

Port:
5432
```

を許可。

Container起動時：

```bash
sudo docker run -d \
  --name sprint4-app \
  -p 8080:8080 \
  -e DB_HOST="sprint2-postgres.c7y2kowyu6ih.ap-northeast-1.rds.amazonaws.com" \
  -e DB_PORT="5432" \
  -e DB_NAME="sprint2db" \
  -e DB_USER="postgres" \
  -e DB_PASSWORD="$DB_PASSWORD" \
  <IMAGE>
```

ここで、

```text
-e
=
environment
```

であり、Containerへ環境変数を注入している。

最後の、

```text
<IMAGE>
```

は、

```text
どのDocker ImageからContainerを作るか
```

を指定している。

---

# 11. Functional Test

## Health

```bash
curl http://localhost:8080/health
```

結果：

```text
OK
```

---

## GET

```bash
curl http://localhost:8080/records
```

既存のRDSデータを取得できた。

---

## POST

```bash
curl -X POST http://localhost:8080/records \
  -H "Content-Type: application/json" \
  -d '{"topic":"Docker","memo":"Sprint4 EC2 test"}'
```

結果：

```text
saved
```

再度GET。

```bash
curl http://localhost:8080/records
```

結果：

```json
{
  "id": 5,
  "memo": "Sprint4 EC2 test",
  "topic": "Docker"
}
```

を確認。

つまり、

```text
Client
 ↓
Docker Container
 ↓
Spring Boot
 ↓
JdbcTemplate
 ↓
RDS PostgreSQL
 ↓
INSERT
 ↓
SELECT
 ↓
Client
```

まで正常に動作した。

---

# 12. Phase 7 - Deploy / Rollback

Spring Bootのコードを変更。

変更前：

```java
return "Hello Sprint 3 CI/CD!";
```

変更後：

```java
return "Hello Sprint 4 Docker v2!";
```

---

## Git

変更確認：

```bash
git diff
```

今回の変更のみStage。

```bash
git add src/main/java/com/example/sprint1/HelloController.java
```

Commit：

```bash
git commit -m "Update app for Sprint 4 Docker v2"
```

Commit SHA：

```text
7cb0cad...
```

Push：

```bash
git push origin sprint4-docker
```

---

## CI

PushによりGitHub Actions起動。

```text
Git Commit B
      ↓
GitHub Actions
      ↓
Maven package
      ↓
Docker build
      ↓
Image B
      ↓
ECR
```

Image B：

```text
7cb0cad8ede49e6b2b95aeb0976252b7708dc49d
```

---

# 13. Deploy Version B

EC2へImage BをPull。

```bash
sudo docker pull \
237575223564.dkr.ecr.ap-northeast-1.amazonaws.com/sprint4-app:7cb0cad8ede49e6b2b95aeb0976252b7708dc49d
```

旧Image AもEC2上へ残した。

```text
Image A
0401d19b...

Image B
7cb0cad8...
```

旧Container停止。

```bash
sudo docker stop sprint4-app
```

削除。

```bash
sudo docker rm sprint4-app
```

Image BからContainerを生成。

```bash
sudo docker run -d \
  --name sprint4-app \
  -p 8080:8080 \
  -e DB_HOST="sprint2-postgres.c7y2kowyu6ih.ap-northeast-1.rds.amazonaws.com" \
  -e DB_PORT="5432" \
  -e DB_NAME="sprint2db" \
  -e DB_USER="postgres" \
  -e DB_PASSWORD="$DB_PASSWORD" \
  237575223564.dkr.ecr.ap-northeast-1.amazonaws.com/sprint4-app:7cb0cad8ede49e6b2b95aeb0976252b7708dc49d
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

---

# 14. Rollback

Image BのContainerを停止。

```bash
sudo docker stop sprint4-app
```

削除。

```bash
sudo docker rm sprint4-app
```

旧Image Aを指定。

```bash
sudo docker run -d \
  --name sprint4-app \
  -p 8080:8080 \
  -e DB_HOST="sprint2-postgres.c7y2kowyu6ih.ap-northeast-1.rds.amazonaws.com" \
  -e DB_PORT="5432" \
  -e DB_NAME="sprint2db" \
  -e DB_USER="postgres" \
  -e DB_PASSWORD="$DB_PASSWORD" \
  237575223564.dkr.ecr.ap-northeast-1.amazonaws.com/sprint4-app:0401d19b60e8508edb21c622f0eac8f6ddceeffb
```

確認：

```bash
curl http://localhost:8080/
```

結果：

```text
Hello Sprint 3 CI/CD!
```

Rollback成功。

ソースコードを書き戻したり、再Buildしたりする必要はなかった。

既に保存してある旧Artifactを指定してContainerを再生成するだけで旧Versionへ戻すことができた。

---

# 15. Rollback後のDB確認

Rollback後：

```bash
curl http://localhost:8080/records
```

を実行。

Version Bで追加した、

```text
id=5
topic=Docker
memo=Sprint4 EC2 test
```

が残っていることを確認。

つまり、

```text
Application / Container
→ 削除・再生成可能

Data
→ RDSに独立して永続化
```

できている。

---

# 16. Final State

Rollback検証後、再度Image Bを指定してContainerを生成。

最終確認：

```text
/health
→ OK

/
→ Hello Sprint 4 Docker v2!

/records
→ RDSデータ取得成功
```

最終状態はVersion B。

---

# 17. Troubleshooting

## ECR Authorization Token Expired

Image BをPullしようとした際、

```text
Your authorization token has expired.
Reauthenticate and try again.
```

が発生。

原因：

```text
Dockerが使用していたECR認証情報の期限切れ
```

IAM Role自体が失効したわけではない。

再度、

```bash
aws ecr get-login-password --region ap-northeast-1 | \
sudo docker login \
  --username AWS \
  --password-stdin \
  237575223564.dkr.ecr.ap-northeast-1.amazonaws.com
```

を実行。

その後、

```bash
docker pull
```

成功。

### 学び

```text
IAM Role
=
AWSリソースへアクセスするための認可

ECR Login
=
DockerがECRへアクセスするための認証
```

認証と認可は別である。

---

## sudo Docker Authentication

通常ユーザーで`docker login`したあと、

```bash
sudo docker pull
```

すると認証情報が異なるため失敗した。

そのため、

```bash
sudo docker login
```

を使用。

Docker認証情報は実行ユーザーごとに管理される点を確認した。

---

## DB_HOST Failure

```text
DB_HOST=wrong-db-host
```

としてContainerを起動。

結果：

```text
/health
→ OK

/records
→ HTTP 500
```

ログ：

```text
UnknownHostException: wrong-db-host
```

ContainerがUpでも、依存サービスまで正常とは限らないことを確認した。

---

## docker run -e

以下だけをShellへ入力すると、

```bash
-e DB_HOST="$DB_HOST"
```

```text
-e: command not found
```

となった。

`-e`はLinux Commandではなく、

```text
docker run
```

のOption。

---

# 18. Key Learnings

Sprint 4で特に重要だった考え方。

## Image

```text
アプリケーションを実行するためのArtifact
```

含まれるもの：

```text
Runtime
Application
Libraries
Startup Method
```

---

## Container

```text
Imageから生成される実行個体
```

Containerは削除してもImageから再生成できる。

```text
Image
↓
Container
↓
削除
↓
Image
↓
新しいContainer
```

---

## Configuration

環境ごとの差はImageへ埋め込まず外部から注入する。

```text
Image
+
Configuration
=
Container
```

例：

```text
DB_HOST
DB_PORT
DB_NAME
DB_USER
DB_PASSWORD
```

---

## Data

DBデータはContainerへ保存しない。

AWS環境ではRDSへ永続化。

```text
Container
→ 交換可能

RDS
→ Dataを永続化
```

---

## Artifact Versioning

```text
Image A
0401d19...

Image B
7cb0cad...
```

複数VersionのImageを保持することで、

```text
Deploy
Rollback
Re-Deploy
```

が容易になる。

---

## Immutable Artifact

アプリケーションごとに環境を作り直すのではなく、

```text
Build済みArtifact
```

を各環境へ配布する。

```text
同じArtifact
     +
環境ごとのConfiguration
```

という構成にすることで、環境差を小さくできる。

---

# 19. Sprint 3 → Sprint 4

Sprint 3：

```text
GitHub
↓
JAR
↓
EC2
↓
systemd
↓
Spring Boot
```

Sprint 4：

```text
GitHub
↓
GitHub Actions
↓
Docker Image
↓
ECR
↓
EC2
↓
Docker Container
↓
Spring Boot
```

アプリケーションを直接Serverへ配置する方式から、

```text
ArtifactとしてImageを管理
```

する方式へ進んだ。

---

# 20. Sprint 5への接続

Sprint 4では以下を人間が手動で実行した。

```text
docker pull

docker stop

docker rm

docker run

Health Check

Rollback
```

今後はこのContainer Lifecycleを、

```text
Amazon ECS
Amazon ECS on Fargate
```

などへ管理させる。

Sprint 5では、

```text
ECR
 ↓
ECS
 ↓
Task
 ↓
Container
```

という構成へ発展させる。

最終的には、

```text
Git
↓
CI
↓
Docker Image
↓
Registry
↓
Container Orchestrator
↓
Application
```

というCloud NativeなDeploy Pipelineへ発展させていく。

---

# Sprint 4 Result

Sprint 4で以下を達成した。

- Docker Image作成
- Docker Container実行
- Docker Compose
- PostgreSQL Container
- Named Volume
- Configuration外部化
- Secret管理
- Health Check
- Fault Injection
- GitHub Actions
- OIDC
- Amazon ECR
- Image Tag
- Image Digest
- EC2 Docker Host
- IAM Role
- ECR Authentication
- Docker Pull
- RDS接続
- POST / GET
- Deploy
- Rollback
- Re-Deploy
- Data Persistence

Sprint 4 Complete.