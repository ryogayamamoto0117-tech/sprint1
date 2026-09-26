# Sprint 3 - ALB × Multi-AZ EC2 × systemd × Rolling Deployment

Sprint 2で構築した、

```text
Spring Boot
    ↓
JDBC
    ↓
RDS PostgreSQL
```

というApplicationからDatabaseまでの構成を拡張し、

Sprint 3ではApplication Layerの冗長化と、
Applicationの運用方法について学習した。

今回構築した主な構成は、

```text
Client
    ↓
Application Load Balancer
    ↓
EC2-A / EC2-B
    ↓
Spring Boot
    ↓
RDS PostgreSQL
```

という構成。

単純にEC2を2台作成するだけではなく、

- 異なるAvailability ZoneへのEC2配置
- systemdによるApplication Process管理
- Application Load Balancerによる負荷分散
- Target Group / Health Check
- 片系障害時のサービス継続
- DB依存障害とHealth Checkの限界
- Liveness / Readinessの考え方
- Rolling Deployment
- Rollback
- Logを利用した障害切り分け

まで実際に構築・観測した。

---

## Sprint 3 Goal

Sprint 3の完了条件は以下。

```text
2台のEC2を別AZでsystemd管理
        ↓
ALB経由でRequestを振り分け
        ↓
片系停止時もサービス継続
        ↓
DB依存障害を発生
        ↓
Health Checkの限界を観測
        ↓
Manual Rolling Deployment
        ↓
Rollback
        ↓
動作確認
```

最終的には、

```text
Windows PC
    ↓
ALB
    ↓
EC2 × 2
    ↓
RDS PostgreSQL
```

というWeb Application構成を実際に構築する。

---

# Architecture

Sprint 3では以下の構成を作成した。

```text
Windows PC
    │
    │ HTTP
    │ TCP 80
    ▼
Internet
    │
    ▼
Application Load Balancer
sprint3-alb
    │
    │ HTTP
    │ TCP 8080
    │
    ├────────────────────┐
    │                    │
    ▼                    ▼
EC2-A                  EC2-B
Spring Boot            Spring Boot
systemd                systemd
AZ: 1a                 AZ: 1c
    │                    │
    └─────────┬──────────┘
              │
              │ JDBC / PostgreSQL
              │ TCP 5432
              ▼
        RDS PostgreSQL
```

Application Layerでは、

```text
EC2-A
EC2-B
```

の2台を異なるAvailability Zoneへ配置した。

2台のEC2は同じSpring Boot Applicationを実行し、
同じRDS PostgreSQLへ接続する。

---

## Availability Zone

EC2-A：

```text
Availability Zone:
ap-northeast-1a

Public Subnet:
10.1.1.0/24
```

EC2-B：

```text
Availability Zone:
ap-northeast-1c

Public Subnet:
10.1.4.0/24
```

同じAvailability Zoneへ2台配置するのではなく、

```text
AZ-A
  ↓
EC2-A

AZ-C
  ↓
EC2-B
```

とすることで、
Application ServerをAZ単位で分散した。

ただし、

```text
Application Layer
```

を2AZへ分散したことと、

```text
System全体がMulti-AZ
```

であることは別。

今回のRDS PostgreSQLはSingle-AZ構成のため、

```text
ALB
 ↓
EC2-A / EC2-B
```

は冗長化されているが、

```text
RDS PostgreSQL
```

はSingle Point of Failureになり得る。

---

# Network

使用しているVPC：

```text
10.1.0.0/16
```

Application Server用Public Subnet：

```text
EC2-A

10.1.1.0/24
ap-northeast-1a
```

```text
EC2-B

10.1.4.0/24
ap-northeast-1c
```

RDS用Private Subnet：

```text
10.1.2.0/24
ap-northeast-1a
```

```text
10.1.3.0/24
ap-northeast-1c
```

大きく、

```text
Public Subnet
    ↓
ALB / EC2

Private Subnet
    ↓
RDS
```

という役割分担になっている。

---

# Sprint 3 Starting Point

Sprint 2終了時点では、

```text
Windows PC
    ↓ HTTP :8080
EC2
    ↓
Spring Boot
    ↓
JDBC
    ↓ PostgreSQL :5432
RDS PostgreSQL
```

という構成だった。

Application Processは、

```text
java -jar app.jar
```

によって手動起動していた。

Sprint 3ではここから、

```text
Application Process Management
Load Balancing
High Availability
Deployment
```

の領域へ進んだ。

---

# Instance Identification

2台のEC2をALB配下へ配置すると、

どちらのEC2がRequestを処理したのかを確認する必要がある。

そのため、

```text
GET /instance
```

Endpointを追加した。

Spring BootではEnvironment VariableからInstance名を取得する。

例：

```java
@Value("${INSTANCE_NAME:unknown}")
private String instanceName;

@GetMapping("/instance")
public String instance() {
    return instanceName;
}
```

EC2-Aでは、

```text
INSTANCE_NAME=node-a
```

EC2-Bでは、

```text
INSTANCE_NAME=node-b
```

を設定した。

これによって、

```text
GET /instance
```

を実行すると、

```text
node-a
```

または、

```text
node-b
```

が返る。

ApplicationのBuild Artifactは同じでも、
Environment Variableによって各Server固有の値を外部から設定できる。

---

# External Configuration

Application固有のSecretやServerごとの値を、

Source Codeへ直接記述しないようにした。

使用した設定ファイル：

```text
/etc/sprint1/sprint1.env
```

内容：

```text
DB_PASSWORD=<SECRET>

INSTANCE_NAME=node-a
```

EC2-Bでは、

```text
INSTANCE_NAME=node-b
```

とする。

`DB_PASSWORD`の実際の値はGitHubへ保存しない。

Permission：

```bash
sudo chmod 600 /etc/sprint1/sprint1.env
```

`600`は、

```text
Owner:
read
write

Group:
なし

Others:
なし
```

というPermission。

これによってEnvironment Fileを一般Userから読み取られにくくする。

---

# systemd

Sprint 2ではSpring Bootを、

```bash
java -jar app.jar
```

で直接起動していた。

この方法では、

SSH Session内でProcessを手動管理する必要がある。

Sprint 3では、

```text
systemd
```

によってSpring Boot ApplicationをServiceとして管理した。

---

## systemd Unit File

作成したUnit File：

```text
/etc/systemd/system/sprint1.service
```

内容：

```ini
[Unit]
Description=Sprint1 Spring Boot Application
After=network.target

[Service]
User=ec2-user
WorkingDirectory=/home/ec2-user/sprint1
EnvironmentFile=/etc/sprint1/sprint1.env
ExecStart=/usr/bin/java -jar /home/ec2-user/sprint1/app.jar
Restart=on-failure

[Install]
WantedBy=multi-user.target
```

---

# systemd Structure

今回の構造：

```text
systemd
   ↓
sprint1.service
   ↓
EnvironmentFile
   ↓
/etc/sprint1/sprint1.env
   ↓
DB_PASSWORD
INSTANCE_NAME
```

さらに、

```text
systemd
   ↓
ExecStart
   ↓
/usr/bin/java
   ↓
app.jar
   ↓
Spring Boot
```

という流れになる。

---

# systemctl

systemdのService操作には、

```text
systemctl
```

を使用する。

起動：

```bash
sudo systemctl start sprint1
```

停止：

```bash
sudo systemctl stop sprint1
```

再起動：

```bash
sudo systemctl restart sprint1
```

状態確認：

```bash
sudo systemctl status sprint1
```

---

## start and enable

`start`と`enable`は意味が異なる。

```text
systemctl start

→ 今Serviceを起動する
```

```text
systemctl enable

→ OS起動時に自動起動する設定
```

自動起動設定：

```bash
sudo systemctl enable sprint1
```

確認：

```bash
systemctl is-enabled sprint1
```

結果：

```text
enabled
```

つまり、

```text
start
= 現在のProcess状態

enable
= 次回以降のBoot時の自動起動設定
```

という違い。

---

# daemon-reload

Unit Fileを新規作成・変更した場合、

```bash
sudo systemctl daemon-reload
```

を実行する。

これは、

```text
Unit Fileを変更
       ↓
systemd Managerへ再読込を指示
       ↓
新しいService定義を認識
```

という処理。

Application自体を再起動するコマンドではない。

---

# journalctl

systemd管理下のApplication Log確認には、

```bash
sudo journalctl -u sprint1
```

を使用した。

最近の50行：

```bash
sudo journalctl -u sprint1 -n 50 --no-pager
```

各Option：

```text
-u

= unit
→ 確認するServiceを指定
```

```text
-n 50

→ 最近の50行
```

```text
--no-pager

→ lessなどを使用せず直接表示
```

Application Error発生時に、

```text
HTTP Response
    ↓
Application Log
    ↓
Exception
    ↓
Caused by
```

と追跡するために使用した。

---

# SSH and systemd

systemdでApplicationを起動した後、

SSH Sessionを切断してもApplicationは動作を継続した。

```text
SSH Session
    ↓
Disconnect

Application
    ↓
Still Running
```

これはSpring Boot ProcessがSSH Shellに直接依存せず、

```text
systemd
```

によって管理されているため。

Sprint 2の、

```bash
java -jar app.jar
```

による手動管理との大きな違い。

---

# EC2-B

Application Serverを冗長化するため、
2台目のEC2を作成した。

```text
EC2-A
ap-northeast-1a
```

```text
EC2-B
ap-northeast-1c
```

EC2-Bにも、

```text
Java 17
app.jar
systemd Unit
Environment File
```

を配置した。

確認：

```bash
curl http://localhost:8080/health
```

結果：

```text
OK
```

Instance確認：

```bash
curl http://localhost:8080/instance
```

結果：

```text
node-b
```

---

# Shared RDS

EC2-AとEC2-Bは同じRDS PostgreSQLへ接続する。

```text
EC2-A
   \
    \
     → RDS PostgreSQL
    /
   /
EC2-B
```

EC2-Bから、

```bash
curl http://localhost:8080/records
```

を実行すると、

EC2-Aから登録していた既存Recordも取得できた。

つまり、

```text
Application Server A
Application Server B
```

が別々でも、

```text
Persistent Data
```

は共通のDatabaseへ保存されている。

Application Serverは交換可能だが、
DataはRDSに永続化されている。

---

# Application Load Balancer

2台のEC2へRequestを分散するため、

```text
Application Load Balancer
```

を作成した。

ALB：

```text
sprint3-alb
```

構成：

```text
Internet-facing
IPv4
```

ALBは2つのPublic Subnetへ配置した。

```text
ap-northeast-1a
10.1.1.0/24
```

```text
ap-northeast-1c
10.1.4.0/24
```

---

# Listener

ALB Listener：

```text
HTTP
Port 80
```

Forward先：

```text
sprint3-tg
```

通信：

```text
Client
   ↓
HTTP :80
   ↓
ALB
```

ClientはSpring Bootの8080へ直接アクセスするのではなく、

ALBの80番PortへRequestを送る。

---

# Target Group

作成したTarget Group：

```text
sprint3-tg
```

Target Type：

```text
Instances
```

Protocol：

```text
HTTP
```

Port：

```text
8080
```

登録したTarget：

```text
EC2-A :8080

EC2-B :8080
```

通信：

```text
ALB
 ↓ HTTP :8080
Target Group
 ↓
EC2-A / EC2-B
```

---

# Health Check

Target GroupのHealth Check Path：

```text
/health
```

Spring Bootの、

```text
GET /health
```

は正常時、

```text
HTTP 200
```

を返す。

ALBは定期的に、

```text
EC2-A:8080/health
EC2-B:8080/health
```

へRequestを送る。

正常なResponse Codeが返れば、

```text
Healthy
```

と判定する。

---

# Health Check and Response Body

今回の`/health`は、

```text
OK
```

というBodyも返す。

ただしALBのHealth Checkで重要なのは、
基本的には設定したHTTP Status Code Matcher。

今回の場合、

```text
200
```

が正常Responseとして使用される。

つまり、

```text
Body = OKだからHealthy
```

ではなく、

```text
HTTP Status Code = 200
        ↓
Healthy
```

という考え方。

---

# Security Group

Sprint 3では、

```text
Client
    ↓
ALB
    ↓
EC2
    ↓
RDS
```

という通信経路に合わせてSecurity Groupを設計した。

---

## ALB Security Group

ALB用Security Group：

```text
sprint3-alb-sg
```

Inbound：

```text
HTTP
TCP 80
Source: Client IP
```

これによって、

```text
PC
 ↓
ALB :80
```

を許可する。

---

## EC2 Security Group

EC2では、

```text
TCP 8080
Source:
sprint3-alb-sg
```

を許可した。

つまり、

```text
ALB Security Group
        ↓
EC2 Security Group
        ↓
TCP 8080
```

というSecurity Group間の許可。

IPアドレスではなく、

```text
ALB Security Group
```

をSourceとして指定している。

---

## RDS Security Group

RDSでは、

```text
PostgreSQL
TCP 5432
Source:
EC2 Security Group
```

を許可している。

構造：

```text
ALB SG
   ↓ :8080
EC2 SG
   ↓ :5432
RDS SG
```

---

## Direct Access to EC2

構築・検証途中では、

```text
PC
 ↓
EC2 :8080
```

の直接通信も一時的に使用した。

最終的なApplication通信は、

```text
PC
 ↓
ALB :80
 ↓
EC2 :8080
```

へ集約する。

そのため、
ALB経由の動作確認後はEC2への直接8080許可を不要にできる。

SSH管理用の、

```text
PC
 ↓
EC2 :22
```

はApplication通信とは別。

---

# Initial ALB Failure

Target GroupへEC2-A / EC2-Bを登録した直後、

Targetが、

```text
Unhealthy
```

になった。

Health Check Error：

```text
Request timed out
```

この時点で、

```text
Spring Boot Process
```

自体は起動していた。

またEC2内部では、

```bash
curl http://localhost:8080/health
```

が成功していた。

つまり、

```text
Spring Boot
TCP 8080
/health
```

までは正常。

問題は、

```text
ALB
 ↓
EC2 :8080
```

の通信経路にあると判断した。

---

# ALB Security Group Troubleshooting

EC2 Security Groupを確認すると、

ALB Security Groupから8080への通信が許可されていなかった。

追加したRule：

```text
Custom TCP
Port 8080
Source:
sprint3-alb-sg
```

追加後、

```text
Unhealthy
    ↓
Healthy
```

へ変化した。

この障害では、

```text
localhost:8080/health
→ OK
```

だったため、

Application自身ではなく、

```text
ALB
 ↓
Network
 ↓
Security Group
 ↓
EC2 :8080
```

を確認することで原因を切り分けることができた。

---

# Load Balancing Check

ALBのDNS Nameを使用して、

```text
GET /instance
```

へRequestを送った。

結果：

```text
node-a
```

または、

```text
node-b
```

が返った。

複数回Requestすると、

```text
ALB
 ├── EC2-A
 └── EC2-B
```

の両方へRequestが送られていることを確認した。

これは、

```text
Client
 ↓
ALB
 ↓
Target Group
 ↓
Healthy Target
```

という経路でRequestが分散されていることを意味する。

なお、

```text
A
B
A
B
```

のように必ず交互になるわけではない。

Load BalancerはRequestをTargetへ分散するが、
単純な厳密交互処理とは限らない。

---

# Intentional Application Failure

High Availabilityを確認するため、

EC2-AのApplicationを意図的に停止した。

```bash
sudo systemctl stop sprint1
```

確認：

```bash
sudo systemctl status sprint1
```

その後Target Groupを確認すると、

```text
EC2-A
→ Unhealthy

EC2-B
→ Healthy
```

となった。

---

# Service Continuity

EC2-AがUnhealthyになった状態で、

ALB経由で、

```text
GET /instance
```

を複数回実行した。

結果：

```text
node-b
node-b
node-b
```

となった。

つまり、

```text
EC2-A
  ↓
停止
```

しても、

```text
ALB
 ↓
EC2-B
```

によってサービスを継続できた。

これによってApplication Layerの冗長化を実際に確認した。

---

# Restore EC2-A

EC2-AのApplicationを再起動。

```bash
sudo systemctl start sprint1
```

Target Groupでは、

```text
Unhealthy
    ↓
Healthy
```

へ復帰した。

再び、

```text
node-a
node-b
```

の両方がResponseとして確認できた。

---

# systemctl stop and Exit Status 143

EC2-Aを停止した際、

Application Log上ではSpring Boot / Tomcat / HikariCPが
Graceful Shutdownしていた。

一方でsystemdでは、

```text
status=143
```

が表示され、

```text
Failed with result 'exit-code'
```

となる場面があった。

これはApplicationが異常Crashしたことを
そのまま意味するわけではない。

ProcessはSIGTERMを受けて終了しており、

Application LogではShutdown処理が実行されていた。

そのため、

```text
systemd上の状態
```

だけを見るのではなく、

```text
Application Log
Process終了理由
実際のShutdown処理
```

を合わせて確認する必要がある。

また、

```bash
systemctl stop
```

による明示的な停止では、

`Restart=on-failure`を設定していても、
ユーザーが意図的に停止したServiceが直ちに再起動されるわけではない。

---

# Database Dependency Failure

次に、

```text
Applicationは起動している
```

が、

```text
Databaseへ正常接続できない
```

という障害を意図的に発生させた。

EC2-Aの、

```text
/etc/sprint1/sprint1.env
```

に設定している、

```text
DB_PASSWORD
```

を意図的に誤った値へ変更した。

その後Applicationを起動した。

---

# /health Result

EC2-Aで、

```bash
curl http://localhost:8080/health
```

を実行。

結果：

```text
OK
```

HTTP Status：

```text
200
```

つまり、

```text
Spring Boot Application
```

自体はHTTP Requestへ応答できる。

---

# /records Result

一方、

```bash
curl http://localhost:8080/records
```

を実行すると、

```text
500 Internal Server Error
```

になった。

この結果から、

```text
HTTP :8080
    ↓
Spring Boot
```

までは正常だが、

```text
Spring Boot
    ↓
JDBC
    ↓
RDS PostgreSQL
```

のどこかで失敗していると判断できる。

---

# Database Error Log

`journalctl`を使用してApplication Logを確認した。

```bash
sudo journalctl -u sprint1 -n 50 --no-pager
```

最初に確認できたException：

```text
CannotGetJdbcConnectionException:
Failed to obtain JDBC Connection
```

さらにException Chainを追うと、

```text
org.postgresql.util.PSQLException:
FATAL: password authentication failed for user "postgres"
```

を確認した。

---

# Error Layer Analysis

このErrorから、

```text
EC2
 ↓
Network
 ↓
RDS :5432
 ↓
PostgreSQL
```

までは到達している。

もしNetwork Layerで接続できていなければ、

```text
timeout
connection refused
```

など別のErrorになる可能性が高い。

今回はPostgreSQL自身が、

```text
password authentication failed
```

を返している。

つまり、

```text
Network
→ OK

RDS到達
→ OK

PostgreSQL
→ OK

Authentication
→ Failure
```

と判断できる。

---

# Health Check Limitation

Database接続に失敗しているEC2-Aを
Target Groupで確認した。

結果：

```text
Healthy
```

だった。

つまり、

```text
/health
→ 200 OK
```

であるため、

ALBはEC2-Aを正常Targetとして扱っていた。

しかし、

```text
/records
→ 500
```

となる。

これによって、

```text
Health Checkが成功
```

と、

```text
Applicationの全機能が正常
```

は同じ意味ではないことを確認した。

---

# ALB and DB Failure

DB Passwordが誤った状態のEC2-Aと、

正常なEC2-BをALB配下へ置いた。

```text
ALB
 ├── EC2-A
 │      /health  → 200
 │      /records → 500
 │
 └── EC2-B
        /health  → 200
        /records → 200
```

ALBから見ると、

```text
EC2-A
Healthy

EC2-B
Healthy
```

となる。

そのため、

```text
GET /records
```

がEC2-Aへ送られた場合は500、

EC2-Bへ送られた場合は正常Responseになる。

実際に、

```text
正常なrecords Response
```

と、

```text
500 Error
```

の両方を観測した。

---

# Liveness

今回の、

```text
/health
```

は、

```text
Application Processが起動し、
HTTP RequestへResponseできるか
```

を確認するEndpoint。

これは概念的には、

```text
Liveness
```

に近い。

質問：

```text
Applicationは生きているか？
```

に答える。

---

# Readiness

一方、

```text
Applicationが実際にRequestを処理できる状態か？
```

を確認する考え方が、

```text
Readiness
```

に近い。

例えば、

```text
/ready
```

Endpointを作成し、

```text
Application
 +
Database Connection
```

を確認するとする。

Database正常：

```text
/ready
→ 200
```

Database異常：

```text
/ready
→ 503
```

とすれば、

ALB Health Checkを`/ready`へ設定することで、

DB依存障害時にTargetをUnhealthyへできる可能性がある。

ただしSprint 3では`/ready`は実装していない。

---

# Readiness Design

すべての依存ServiceをHealth Checkへ含めればよいとは限らない。

例えば、

```text
Application
 ↓
Database
 ↓
External API
 ↓
Other Service
```

のすべてをHealth Check条件にすると、

1つの依存Service障害によって多数のApplication Serverが、

```text
Unhealthy
```

になる可能性がある。

そのため、

```text
何をHealth Checkへ含めるか
```

はAvailability Designとして考える必要がある。

---

# Restore Database Configuration

障害確認後、

EC2-Aの`DB_PASSWORD`を正常な値へ戻した。

Applicationを再起動。

確認：

```bash
curl http://localhost:8080/records
```

結果：

```text
正常にRecord取得
```

Target Groupも、

```text
EC2-A
Healthy

EC2-B
Healthy
```

へ戻した。

---

# Rolling Deployment

次にApplicationのVersion Updateを行った。

目的は、

```text
2台同時停止
```

を避けながらDeploymentすること。

最初の状態：

```text
ALB
 ├── EC2-A v1
 └── EC2-B v1
```

更新後：

```text
ALB
 ├── EC2-A v2
 └── EC2-B v2
```

へ移行する。

---

# Application Version Change

Spring BootのRoot Endpointを変更した。

変更前：

```java
@GetMapping("/")
public String home() {
    return "Hello Sprint 1!";
}
```

変更後：

```java
@GetMapping("/")
public String home() {
    return "Hello Sprint 3 v2!";
}
```

これによって、
Deployment後のVersionをHTTP Responseから確認できるようにした。

---

# Maven Build

WindowsでApplicationをBuild。

```powershell
.\mvnw.cmd clean package
```

処理：

```text
clean
 ↓
以前のBuild Result削除
 ↓
compile
 ↓
test
 ↓
package
 ↓
JAR生成
```

生成物：

```text
target/sprint1-0.0.1-SNAPSHOT.jar
```

---

# Maven clean Failure

最初のBuildでは、

```text
Failed to clean project
Failed to delete
target\classes\com\example\sprint1
```

というErrorが発生した。

まずJava ProcessがFileを使用している可能性を考え、

```powershell
Get-Process java -ErrorAction SilentlyContinue
```

を確認した。

Java Processは残っていなかった。

その後、

```text
target
```

Directoryを手動削除した。

`target`はMavenによるBuild生成物であり、

```text
src
```

のようなSource Codeではない。

そのため、

同じBuild Artifact削除Errorの場合は、

```text
Processが掴んでいないか確認
        ↓
targetを削除
        ↓
再Build
```

という対応が可能。

再度、

```powershell
.\mvnw.cmd clean package
```

を実行すると、

```text
BUILD SUCCESS
```

になった。

原因についてはFile Lock等が候補になるが、
今回の確認だけでは特定の原因までは断定していない。

---

# JAR Backup

Deployment前に、
現在動作しているJARをBackupした。

EC2-A：

```bash
cp \
  /home/ec2-user/sprint1/app.jar \
  /home/ec2-user/sprint1/app.jar.bak
```

構造：

```text
app.jar
→ 現在DeploymentされているApplication

app.jar.bak
→ Rollback用Backup
```

Rollbackとは単にFileをCopyする操作そのものではなく、

```text
Systemを以前の正常Versionへ戻すこと
```

を意味する。

今回はその実現手段として、

```text
旧JARをBackup
        ↓
必要時にapp.jarへ戻す
```

という方法を使用した。

---

# Deregister Target

EC2-AをUpdateする前に、
Target GroupからEC2-AをDeregisterした。

状態：

```text
EC2-A
Draining

EC2-B
Healthy
```

この間、

新しいRequestは基本的にEC2-Bへ送られる。

---

# Connection Draining

TargetをDeregisterした直後に
即座にすべてのConnectionを切断するわけではない。

Targetは、

```text
Draining
```

状態になる。

これは、

```text
既存Connection
    ↓
処理を終える時間を確保
    ↓
Targetから除外
```

という考え方。

Applicationを更新する前にTrafficを外すことで、

処理中Requestへの影響を減らす。

---

# Deploy EC2-A

EC2-AがTarget Groupから外れた後、

Applicationを停止。

```bash
sudo systemctl stop sprint1
```

Windowsから新しいJARを転送。

```powershell
scp -i "path/to/key.pem" `
  ".\target\sprint1-0.0.1-SNAPSHOT.jar" `
  ec2-user@<EC2_A_PUBLIC_IP>:/home/ec2-user/sprint1/app.jar
```

起動：

```bash
sudo systemctl start sprint1
```

---

# Verify EC2-A v2

まずALBへ戻す前に、
EC2-A内部で確認した。

Version確認：

```bash
curl http://localhost:8080/
```

結果：

```text
Hello Sprint 3 v2!
```

Database確認：

```bash
curl http://localhost:8080/records
```

結果：

```text
正常にRecord取得
```

つまり、

```text
Application v2
        ↓
Spring Boot
        ↓
JDBC
        ↓
RDS
```

まで正常。

その後、
EC2-AをTarget Groupへ再登録した。

状態：

```text
EC2-A
Healthy

EC2-B
Healthy
```

---

# Deploy EC2-B

次にEC2-BをTarget GroupからDeregisterした。

この時点では、

```text
EC2-A v2
Healthy
```

がRequestを処理する。

構成：

```text
ALB
 ↓
EC2-A v2

EC2-B
Deployment中
```

EC2-Bを停止。

```bash
sudo systemctl stop sprint1
```

旧JARをBackup。

```bash
cp \
  /home/ec2-user/sprint1/app.jar \
  /home/ec2-user/sprint1/app.jar.bak
```

新しいJARをSCP。

```powershell
scp -i "path/to/key.pem" `
  ".\target\sprint1-0.0.1-SNAPSHOT.jar" `
  ec2-user@<EC2_B_PUBLIC_IP>:/home/ec2-user/sprint1/app.jar
```

起動：

```bash
sudo systemctl start sprint1
```

確認：

```bash
curl http://localhost:8080/
```

結果：

```text
Hello Sprint 3 v2!
```

その後Target Groupへ再登録。

---

# Rolling Deployment Flow

今回行ったDeployment全体：

```text
Initial

ALB
 ├── A v1
 └── B v1

        ↓

A Deregister

ALB
 └── B v1

Aをv2へUpdate

        ↓

A Register

ALB
 ├── A v2
 └── B v1

        ↓

B Deregister

ALB
 └── A v2

Bをv2へUpdate

        ↓

B Register

ALB
 ├── A v2
 └── B v2
```

2台を一度に停止せず、

```text
片方がTrafficを処理
        ↓
もう片方をUpdate
```

という形でDeploymentした。

これがRolling Deployment / Rolling Updateに近い考え方。

---

# ALB Version Check

2台のDeployment完了後、

ALB経由で、

```text
GET /
```

へRequest。

結果：

```text
Hello Sprint 3 v2!
```

となった。

つまり、

```text
Client
 ↓
ALB
 ↓
EC2 v2
```

まで新Versionが反映されていることを確認した。

---

# Rollback

新Versionに問題があった場合を想定し、
Rollbackも実施した。

対象：

```text
EC2-A
```

まずTarget GroupからDeregister。

```text
EC2-A
Draining

EC2-B
Healthy
```

Trafficが外れた後、

Applicationを停止。

```bash
sudo systemctl stop sprint1
```

---

# Restore Previous JAR

Backupしていた、

```text
app.jar.bak
```

を、

```text
app.jar
```

へ戻した。

```bash
cp \
  /home/ec2-user/sprint1/app.jar.bak \
  /home/ec2-user/sprint1/app.jar
```

Application起動：

```bash
sudo systemctl start sprint1
```

---

# Verify Rollback

確認：

```bash
curl http://localhost:8080/
```

結果：

```text
Hello Sprint 1!
```

旧Versionへ戻った。

Database確認：

```bash
curl http://localhost:8080/records
```

結果：

```text
正常にRecord取得
```

つまり、

```text
Application Version
v2 → v1
```

へ戻しても、

```text
RDS Data
```

はそのまま利用できた。

---

# Rollback Flow

今回のRollback：

```text
A v2
 ↓
Deregister
 ↓
Draining
 ↓
Stop
 ↓
app.jar.bak
 ↓
app.jarへCopy
 ↓
Start
 ↓
Version Check
 ↓
DB Check
 ↓
Register
```

これによって、

```text
Deployment
```

だけではなく、

```text
Recovery
```

まで実際に経験した。

---

# Restore Final Version

Rollback確認後、

最終状態をv2へ揃えるため、
EC2-Aを再びv2へDeploymentした。

```text
EC2-A
v1
 ↓
Deregister
 ↓
Stop
 ↓
v2 JAR転送
 ↓
Start
 ↓
Verify
 ↓
Register
```

最終状態：

```text
ALB
 ├── EC2-A v2 / Healthy
 └── EC2-B v2 / Healthy
```

---

# Identify Current EC2

SSH作業中に、

```text
今どちらのEC2へ接続しているか
```

を確認したい場面があった。

Applicationレベルでは、

```bash
curl http://localhost:8080/instance
```

を使用できる。

EC2-A：

```text
node-a
```

EC2-B：

```text
node-b
```

OS Levelでは、

```bash
hostname
```

でもHostを確認できる。

ただし、

```text
/instance
```

はApplication自身がどのInstance設定で動いているのか確認できるため、
今回の構成では特に分かりやすい。

---

# Replacing JAR While Process is Running

Linuxでは、
実行中Processが使用しているFileを置き換えられる場合もある。

ただし、

```text
Running Process
→ Old Version

Disk上のapp.jar
→ New Version
```

という不一致が発生すると、

現在動作しているVersionが分かりにくくなる。

そのため今回の運用では、

```text
Deregister
 ↓
Stop
 ↓
Replace JAR
 ↓
Start
 ↓
Verify
 ↓
Register
```

という順序を使用した。

重要なのは、

```text
Disk上のArtifact
```

と、

```text
Memory上で動作中のProcess
```

は別物であるということ。

---

# Manual Deployment

Sprint 3で実施したDeploymentは、

まだ自動化されていない。

人間が、

```text
Code Change
 ↓
Maven Build
 ↓
JAR
 ↓
Target Deregister
 ↓
Stop
 ↓
SCP
 ↓
Start
 ↓
HTTP Check
 ↓
DB Check
 ↓
Target Register
 ↓
Healthy Check
```

を実行している。

---

# Why CI/CD is Needed

Manual Rolling Deploymentでは、
操作項目がさらに増えた。

```text
Build
 ↓
Target Control
 ↓
Process Stop
 ↓
Artifact Transfer
 ↓
Process Start
 ↓
Application Verification
 ↓
Target Register
 ↓
Health Check
```

人間が毎回実施すると、

```text
Deregisterを忘れる

古いJARを転送する

Stopを忘れる

Startを忘れる

Health Checkを忘れる

片方だけVersionが違う

Rollback Artifactを用意していない
```

などのHuman Errorが発生する可能性がある。

将来的には、

```text
git push
 ↓
Test
 ↓
Build
 ↓
Artifact
 ↓
Deploy
 ↓
Verify
```

といった処理をCI/CDによって自動化する。

Sprint 2では、

```text
Manual Deployment
```

を経験した。

Sprint 3ではさらに、

```text
複数Serverへ順番にDeployment
```

を経験したことで、

CI/CDによって自動化する対象がより具体的になった。

---

# Troubleshooting Layer

Sprint 1では、

```text
Code
 ↓
Build
 ↓
JAR
 ↓
Linux
 ↓
Java Process
 ↓
Port
 ↓
HTTP
 ↓
Network
```

を中心に確認した。

Sprint 2ではその先に、

```text
JDBC
 ↓
RDS
 ↓
PostgreSQL
 ↓
Authentication
 ↓
SQL
 ↓
Persistence
```

が追加された。

Sprint 3ではさらに、

```text
ALB
 ↓
Listener
 ↓
Target Group
 ↓
Health Check
 ↓
Security Group
 ↓
EC2-A / EC2-B
 ↓
systemd
 ↓
Java Process
 ↓
Spring Boot
 ↓
JDBC
 ↓
RDS
```

まで確認範囲が広がった。

---

# Sprint 3 Troubleshooting Examples

今回の代表的な障害をLayerごとに整理する。

```text
ALB Target
Request timed out
        ↓
ALB → EC2通信を確認
        ↓
Security Group
        ↓
ALB SG → EC2 :8080許可不足
```

```text
/health
200 OK

/records
500
        ↓
Spring Bootは起動済み
        ↓
DB依存処理を確認
        ↓
CannotGetJdbcConnectionException
        ↓
PSQLException
        ↓
password authentication failed
```

```text
Maven clean Failure
        ↓
targetを削除できない
        ↓
Java Process確認
        ↓
Build Artifact確認
        ↓
target削除
        ↓
再Build
```

問題を、

```text
Applicationが動かない
```

という1つの問題として見るのではなく、

```text
① Client
② ALB
③ Listener
④ Target Group
⑤ Health Check
⑥ Security Group
⑦ EC2
⑧ systemd
⑨ Java Process
⑩ Port
⑪ HTTP
⑫ Controller
⑬ JDBC
⑭ Network
⑮ RDS
⑯ PostgreSQL
⑰ Authentication
⑱ SQL
```

というLayerへ分解して考える。

---

# High Availability

Sprint 3でApplication Layerを、

```text
Single Server
```

から、

```text
Multiple Servers
```

へ変更した。

Sprint 2：

```text
Client
 ↓
EC2
 ↓
RDS
```

EC2が停止すると、

```text
Service停止
```

になる。

Sprint 3：

```text
Client
 ↓
ALB
 ├── EC2-A
 └── EC2-B
       ↓
      RDS
```

EC2-Aが停止しても、

```text
ALB
 ↓
EC2-B
```

によってApplication Serviceを継続できる。

---

# High Availability Limitation

ただし、
今回の構成ですべてのSingle Point of Failureが
なくなったわけではない。

Application Layer：

```text
EC2-A
EC2-B
```

で冗長化。

Database Layer：

```text
RDS PostgreSQL
Single-AZ
```

のまま。

つまり、

```text
Application Availability
```

は向上したが、

```text
Database Availability
```

については今後さらに改善余地がある。

---

# ALB and Application Port

Sprint 2では、

```text
Client
 ↓
EC2 :8080
```

へ直接アクセスしていた。

Sprint 3では、

```text
Client
 ↓
ALB :80
 ↓
EC2 :8080
```

へ変化した。

このためBrowserからALBへアクセスする際は、

```text
:8080
```

をURLへ指定する必要がない。

Portの役割：

```text
Client → ALB
TCP 80
```

```text
ALB → Spring Boot
TCP 8080
```

同じHTTP通信でも、
通信区間によってPortが異なる。

---

# curl

Sprint 3ではApplication確認に`curl`を多用した。

例：

```bash
curl http://localhost:8080/health
```

```bash
curl http://localhost:8080/instance
```

```bash
curl http://localhost:8080/records
```

Browserと同じようにHTTP Requestを送信できるため、

Server上でApplicationを直接確認する際に使用できる。

例えば、

```text
Browser
 ↓
ALB
 ↓
EC2
```

ではなく、

```text
EC2
 ↓ localhost:8080
 ↓
Spring Boot
```

を直接確認できる。

これによって、

```text
ALBの問題
```

と、

```text
Applicationの問題
```

を切り分けることができる。

---

# Sprint 3 Result

Sprint 3では以下の流れを一通り経験した。

```text
Sprint 2 Application
        ↓
/instance Endpoint
        ↓
External Configuration
        ↓
systemd
        ↓
Service Management
        ↓
Auto Start
        ↓
EC2-B
        ↓
Multi-AZ Application Servers
        ↓
Shared RDS
        ↓
Application Load Balancer
        ↓
Listener
        ↓
Target Group
        ↓
Health Check
        ↓
Security Group
        ↓
Load Balancing
        ↓
Intentional Server Failure
        ↓
Target Unhealthy
        ↓
Service Continuity
        ↓
Recovery
        ↓
Intentional DB Failure
        ↓
HTTP 500
        ↓
journalctl
        ↓
Exception Analysis
        ↓
Health Check Limitation
        ↓
Liveness / Readiness
        ↓
Application v2
        ↓
Maven Build
        ↓
JAR Backup
        ↓
Target Deregistration
        ↓
Connection Draining
        ↓
Rolling Deployment
        ↓
Version Verification
        ↓
Rollback
        ↓
Recovery Verification
        ↓
Final v2 Deployment
```

---

# Learning Progress

Sprint 1では、

```text
Code
→ Build
→ Artifact
→ Server
→ Process
→ Port
→ HTTP
→ Network
```

を学習した。

Sprint 2では、

```text
Database
→ JDBC
→ SQL
→ Persistence
→ Authentication
```

を追加した。

Sprint 3では、

```text
Process Management
→ Multi-AZ
→ Load Balancing
→ Health Check
→ Availability
→ Failure Detection
→ Rolling Deployment
→ Rollback
```

を追加した。

結果として、

```text
Client
    ↓
HTTP
    ↓
Application Load Balancer
    ↓
Target Group
    ↓
Health Check
    ↓
EC2
    ↓
Linux
    ↓
systemd
    ↓
Java Process
    ↓
Spring Boot
    ↓
Controller
    ↓
JDBC
    ↓
Network
    ↓
RDS
    ↓
PostgreSQL
    ↓
Persistent Data
```

という、
Web Application全体の構造をより広い範囲で
構築・観測・障害復旧できるようになった。

さらに、

```text
正常系を作る
```

だけではなく、

```text
Serverを停止する

DB認証を壊す

Health Checkの挙動を見る

Logから原因を追う

Trafficを逃がしてDeploymentする

旧VersionへRollbackする
```

という運用・障害対応も経験した。

Sprint 3を通して、

**Client → ALB → Target Group → EC2 → systemd → Spring Boot → JDBC → RDS**

という通信・実行経路をLayerごとに考え、

問題発生時に一度にすべてを疑うのではなく、

```text
どのLayerまでは正常か
        ↓
どのLayerから異常か
```

を確認しながら原因を切り分ける考え方を身につけた。