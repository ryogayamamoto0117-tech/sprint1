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
    │                    │
    ▼                    ▼
EC2-A                  EC2-B
Spring Boot            Spring Boot
systemd                systemd
AZ: 1a                 AZ: 1c
    │                    │
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
 │      /health  → 200
 │      /records → 500
 │
 └── EC2-B
        /health  → 200
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
---
# Sprint 3 Extension - Operations × Auto Scaling × Security × CI/CD
Sprint 3本体では、
```text
Manual Rolling Deployment
```
までを実施した。
その後のExtensionでは、
```text
Monitoring
    ↓
Auto Scaling
    ↓
Security
    ↓
Continuous Integration
    ↓
Continuous Delivery
    ↓
Automated Rolling Deployment
```
へ学習範囲を拡張した。
Sprint 3本体で人間が手動で行った運用を、
一度仕組みとして理解したうえで自動化していくことを目的とした。
最終的には、
```text
Code Change
    ↓
git push
    ↓
GitHub Actions
    ↓
Maven Build
    ↓
JAR
    ↓
Amazon S3
    ↓
Target Control
    ↓
AWS Systems Manager
    ↓
EC2-B Deployment
    ↓
ALB Healthy
    ↓
EC2-A Deployment
    ↓
ALB Healthy
```
までを自動化した。
---
# Extension Architecture
Sprint 3 Extensionで追加した主な構成：
```text
GitHub
  ↓ push
GitHub Actions Runner
  │
  ├── Maven Build
  │      ↓
  │     JAR
  │      ↓
  ├── Amazon S3
  │
  ├── OIDC
  │      ↓
  │    AWS STS
  │      ↓
  │    IAM Role
  │
  ├── AWS Systems Manager
  │      ↓
  │    EC2-A / EC2-B
  │
  └── Elastic Load Balancing API
         ↓
       Target Group
```
Application実行環境：
```text
ALB
 ├── EC2-A / Spring Boot / systemd
 └── EC2-B / Spring Boot / systemd
          ↓
      RDS PostgreSQL
```
監視・運用では、
```text
CloudWatch
SNS
Auto Scaling
WAF
Systems Manager
IAM
S3
Parameter Store
```
も使用した。
---
# CloudWatch Monitoring
最初に、Sprint 3で構築したALB / EC2をCloudWatchで観測した。
CloudWatchでは、
```text
Systemで起きていること
        ↓
Metricとして数値化
        ↓
時系列で観測
```
する。
今回確認した主なMetric：
```text
ApplicationELB
- HealthyHostCount
- RequestCount
EC2
- CPUUtilization
  ```
---
## HealthyHostCount
Target GroupではALBが定期的に`/health`へRequestを送信している。
```text
ALB
 ↓
/health
 ↓
HTTP Status Code
 ↓
Target Health
```
CloudWatchの`HealthyHostCount`では、
その結果としてHealthyなTargetが何台存在するかを数値として確認できる。
重要なのは、
```text
CloudWatch自身が /health を呼ぶ
```
のではなく、
```text
ALBがHealth Checkを行う
        ↓
その状態をMetricとしてCloudWatchで観測する
```
という関係である。
---
## RequestCount
ALBへ複数回Requestを送り、`RequestCount`の増加を確認した。
最初はStatisticにAverageを使用していたため、
Request数として直感的でない小数値が表示された。
その後、
```text
Metric    : RequestCount
Statistic : Sum
Period    : 5 minutes
```
へ変更した。
これによって、
```text
5分間にALBが処理したRequest数
```
として確認しやすくなった。
ここで、
```text
Metric
×
Statistic
×
Period
```
によってGraphの意味が変わることを理解した。
---
## CPUUtilization
EC2-A / EC2-Bの`CPUUtilization`をCloudWatchへ表示した。
ALBの`RequestCount`と同じ時間軸で確認することで、
```text
Request増加
   ↓
CPU負荷
```
のように複数Metricを関連付けて観測できる。
ただし、
```text
RequestCount = Count
CPUUtilization = Percent
```
で単位が異なるため、Graphを読む際はScaleにも注意する必要がある。
---
# CloudWatch Alarm × SNS
EC2-AのCPUUtilizationに対してAlarmを作成した。
設定：
```text
Metric     : CPUUtilization
Statistic  : Average
Period     : 5 minutes
Condition  : Greater than 70%
Datapoint  : 1
```
Alarm：
```text
Sprint3-node-a-CPU-High
```
SNS Topic：
```text
Sprint3-CPU-Alarm
```
SNS SubscriptionをEmailで確認し、
Alarm発生時に通知が届く構成を作成した。
---
## CPU Alarm Test
EC2-AでCPU負荷を意図的に発生させた。
```bash
yes > /dev/null
```
CPU数確認：
```bash
nproc
```
結果：
```text
2
```
2 vCPUであるため、1つの`yes`だけではCPU全体を100%近くまで使わない。
そのため2つのSSH Sessionから`yes`を実行した。
```text
CPU Load
   ↓
CPUUtilization > 70%
   ↓
CloudWatch Alarm
   ↓
ALARM
   ↓
SNS
   ↓
Email
```
を実際に確認した。
負荷停止後はAlarmが`OK`へ戻った。
また、5分Averageを使用しているため、
瞬間的なCPU上昇ではなく一定期間の平均値で判定され、
検知に時間差が発生することも確認した。
---
# Auto Scaling
次に、EC2を人間が1台ずつ作成する構成から、
Auto Scaling Groupによって必要なInstance数を維持する構成を検証した。
考え方：
```text
Launch Template
= EC2をどう作るか
Auto Scaling Group
= EC2を何台維持するか
```
Launch TemplateをEC2の設計図として使用し、
Auto Scaling Groupがその設計図からEC2を起動する。
---
# Auto Scaling Bootstrap Design
Auto Scalingで起動されるEC2は、
手動SSHによる初期設定を前提にできない。
そのため、
```text
EC2 Launch
   ↓
User Data
   ↓
Java Install
   ↓
S3からJAR取得
   ↓
Parameter StoreからSecret取得
   ↓
systemd設定
   ↓
Application Start
```
までを自動化した。
これによって、
```text
新しいEC2
= 起動後に自分でApplication Serverになる
```
という構成を作成した。
---
# S3 Artifact Storage
Spring BootのJARをPrivate S3 Bucketへ配置した。
用途：
```text
Build Artifact
      ↓
Amazon S3
      ↓
EC2
```
EC2からはIAM Roleを使用して`s3:GetObject`のみを許可した。
Bucket全体をPublicにするのではなく、
必要なEC2へ必要なObject取得権限のみ与える構成とした。
---
# Parameter Store SecureString
Database PasswordをUser Dataへ直接記述しないため、
Systems Manager Parameter Storeを利用した。
Parameter：
```text
/sprint3/db/password
```
Type：
```text
SecureString
```
EC2 Roleへ`ssm:GetParameter`を許可し、
```text
EC2
 ↓ IAM Role
Parameter Store
 ↓
DB_PASSWORD
```
として取得する。
これによって、
```text
SecretをSource Codeへ書かない
SecretをUser Dataへ直接埋め込まない
```
という設計にした。
---
# Auto Scaling IAM Role
Auto Scalingで起動されるEC2へIAM Roleを設定した。
主な権限：
```text
S3 GetObject
SSM GetParameter
```
EC2自身が、
```text
Artifact
Secret
```
を必要なタイミングで取得する。
Access KeyをEC2上へ保存する方式ではなく、
IAM RoleによるTemporary Credentialを利用する。
---
# Launch Template Troubleshooting
最初のUser Dataでは、
```bash
dnf install -y java-17-amazon-corretto-headless curl
```
を実行したところ、Amazon Linux 2023の`curl-minimal`とのConflictが発生した。
そのため、
```bash
dnf install -y java-17-amazon-corretto-headless
```
へ修正した。
ここでは、
```text
Launch失敗
   ↓
User Dataを確認
   ↓
Package Errorを確認
   ↓
Launch TemplateをVersion Update
```
という切り分けを行った。
また、Private ResourceであるS3 / Parameter StoreへアクセスするためのAWS API通信と、
Package Install等に必要なInternet通信の違いも確認した。
今回のPublic Subnet構成では、
EC2へPublic IPv4が付与されない状態でInternetへ出られず、
SubnetのAuto-assign Public IPv4設定も確認・修正した。
---
# Auto Scaling Self Healing
Auto Scaling GroupへALB Target Groupを関連付け、
ELB Health Checkを有効化した。
ASG Instance上のSpring Bootを意図的に停止した。
```text
Spring Boot Stop
      ↓
ALB Health Check Failure
      ↓
Target Unhealthy
      ↓
Auto Scaling Group
      ↓
Unhealthy Instanceを置換
      ↓
New EC2 Launch
      ↓
User Data
      ↓
Spring Boot Start
      ↓
Healthy
```
となることを確認した。
systemdの`Restart=on-failure`と、
Auto ScalingのSelf Healingは役割が異なる。
```text
systemd
→ OS / Process LayerでApplicationを管理
Auto Scaling
→ EC2 Instance Layerで必要台数とHealthを管理
```
という違いを確認した。
---
# Target Tracking Scaling
Target Tracking Scaling Policyを設定した。
設定例：
```text
Metric:
Average CPU Utilization
Target:
50%
```
EC2へCPU負荷を発生させると、
```text
CPU High
  ↓
Scaling Policy
  ↓
Desired Capacity Increase
  ↓
EC2 1台 → 2台
```
を確認した。
負荷を停止すると、一定時間後に、
```text
EC2 2台 → 1台
```
へScale Inした。
ここで、
```text
負荷上昇
 ↓
Scale Out
 ↓
負荷低下
 ↓
Scale In
```
を短時間で繰り返すFlappingを避けるため、
Warmupや評価期間などの設計が重要になることも確認した。
---
# EC2 Purchase Options
Auto Scalingの学習と合わせて、EC2の主な購入方式を整理した。
```text
On-Demand
Savings Plans
Reserved Instances
Spot Instances
```
単純な価格比較ではなく、
```text
Workloadの継続性
中断可能性
利用期間
柔軟性
```
によって選択する必要がある。
特にSpot Instanceは中断される可能性があるため、
Statelessで交換可能なApplication Serverとの相性を考える必要がある。
---
# AWS WAF
Application Load BalancerへAWS WAFを関連付け、
HTTP RequestをApplication到達前に制御する検証を行った。
検証Rule：
```text
URI Path
/waf-test
Action
Block
```
結果：
```text
/health
→ 200 OK
/waf-test
→ 403 Forbidden
```
これによって、
```text
Client
 ↓
WAF
 ↓
ALB
 ↓
EC2
```
という位置で、
WAFがApplicationへ到達する前にRequestをBlockできることを確認した。
検証完了後はWAF Web ACLをALBからDisassociateし、削除した。
---
# GitHub Actions CI
Sprint 3本体ではBuildをWindows PCで手動実行していた。
Extensionでは、GitHubへのPushをTriggerとしてBuildを自動実行した。
Workflow：
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
```
Workflow File：
```text
.github/workflows/ci.yml
```
Maven Build：
```bash
./mvnw clean package
```
これによって、
Developer PCではなくGitHub Actions Runner上でBuildできるようにした。
---
# GitHub Actions Runner
GitHub Actionsでは、Workflow実行時に一時的なRunnerが用意される。
```text
Workflow Start
      ↓
Temporary Runner
      ↓
Checkout
      ↓
Build
      ↓
Workflow End
      ↓
Runner破棄
```
そのためBuildしたJARを後から利用する場合、
Runner内に置いたままでは残らない。
このためGitHub ArtifactやS3へ保存する必要がある。
---
# Maven Wrapper Permission Failure
最初のGitHub Actions CIでは、
```text
./mvnw: Permission denied
Process completed with exit code 126
```
が発生した。
Gitで`mvnw`のModeを確認すると、
```text
100644
```
だった。
Linux Runnerから実行するためにはExecutable Permissionが必要なため、
```bash
git update-index --chmod=+x mvnw
```
を実行した。
変更後：
```text
100755
```
となり、GitHub Actions上でMaven Wrapperを実行できた。
ここで、
```text
Windowsでは問題なく実行できる
        ↓
Linux RunnerではPermission Error
```
というOS / File Permission差分も経験した。
---
# CI Artifact
Build成功後、GitHub ActionsのArtifactとしてJARを保存した。
```text
Maven Build
   ↓
JAR
   ↓
actions/upload-artifact
   ↓
GitHub Artifact
```
これによって、
```text
Source Code
```
だけでなく、
```text
Build Result
```
もWorkflow実行結果として確認できるようになった。
---
# CI and CD
今回の学習では、CIとCDを次のように整理した。
```text
CI
Code
 ↓
Checkout
 ↓
Test / Build
 ↓
JAR
```
```text
CD
JAR
 ↓
Execution Environmentへ配布
 ↓
Application Restart
 ↓
Health Check
```
Mavenは、
```text
Java Source Code
      ↓
Executable JAR
```
を作る。
Deploymentは、
```text
JAR
 ↓
EC2
```
へ届けて実行環境へ反映する。
systemdは、
```text
java -jar app.jar
```
としてApplication Processを起動・管理する。
---
# GitHub Actions to AWS Authentication
GitHub ActionsからAWS APIを操作するため、
Access KeyをGitHub Secretsへ長期間保存する方式ではなくOIDCを利用した。
構造：
```text
GitHub Actions
      ↓
OIDC Token
      ↓
AWS STS
      ↓
AssumeRole
      ↓
Temporary Credential
      ↓
AWS API
```
OIDC：
```text
OpenID Connect
```
STS：
```text
Security Token Service
```
GitHub Actionsが誰であるかをOIDCで確認し、
信頼条件を満たしたWorkflowがIAM RoleをAssumeする。
その後、STSがTemporary Credentialを発行する。
---
# Authentication and Authorization
今回、認証と認可を明確に分けて考えた。
```text
Authentication
= 誰か
Authorization
= 何をしてよいか
```
GitHub Actionsでは、
```text
OIDC
→ Authentication
IAM Role / IAM Policy
→ Authorization
```
という役割分担になる。
OIDC認証が成功しても、
IAM Policyに対象Action / Resourceの権限がなければAWS API操作は失敗する。
---
# GitHub Actions IAM Permissions
CD用IAM Roleには、段階的に必要な権限を追加した。
主なAction：
```text
s3:PutObject
ssm:SendCommand
ssm:GetCommandInvocation
elasticloadbalancing:DeregisterTargets
elasticloadbalancing:RegisterTargets
elasticloadbalancing:DescribeTargetHealth
```
最初からAdministratorAccessを付けるのではなく、
Workflowが必要とするOperationを確認しながら追加した。
Rolling Deployment検証時のElastic Load Balancing操作については、
まず動作確認を優先してResourceを広めに設定し、
今後さらにResource Levelで絞り込む余地を残した。
---
# EC2 CD IAM Role
EC2-A / EC2-BにはCD用IAM Roleを付与した。
主な権限：
```text
AmazonSSMManagedInstanceCore
S3 GetObject
```
これによって、
```text
GitHub Actions
      ↓
Systems Manager
      ↓
EC2
```
という経路でCommandを送信できる。
EC2はS3から指定されたJARを取得できる。
---
# Systems Manager instead of SSH
Sprint 3本体のManual Deploymentでは、
```text
Windows PC
   ↓ SSH / SCP
EC2
```
だった。
CI/CDでは、
```text
GitHub Actions
   ↓ AWS API
Systems Manager
   ↓ SSM Agent
EC2
```
へ変更した。
これは、
```text
GitHub Actionsが自動SSHする
```
という構成ではない。
PEM Private KeyをGitHubへ保存してSSHするのではなく、
IAMとSystems Managerを利用してCommandを実行する。
Linux Command自体はEC2上で引き続き実行される。
---
# Systems Manager Run Command Test
まずGitHub Actionsへ組み込む前に、Systems Manager Run Commandを手動実行した。
確認Command：
```bash
whoami
hostname
systemctl is-active sprint1
```
結果：
```text
root
<EC2 hostname>
active
```
となり、
Systems Manager経由でEC2上のCommandを実行できることを確認した。
---
# S3 Based Deployment
GitHub Actionsで生成したJARをS3へUploadした。
Object：
```text
s3://<artifact-bucket>/cd/app.jar
```
DeploymentではEC2自身がこのObjectを取得する。
```text
GitHub Actions
     ↓ PutObject
S3
     ↓ GetObject
EC2
```
S3をBuild Artifactの中継点として利用した。
---
# Automated EC2 Deployment Command
Systems ManagerでEC2上に次の処理を実行した。
```bash
set -e
cp /home/ec2-user/sprint1/app.jar /home/ec2-user/sprint1/app.jar.bak
aws s3 cp s3://<artifact-bucket>/cd/app.jar /home/ec2-user/sprint1/app.jar.new
mv /home/ec2-user/sprint1/app.jar.new /home/ec2-user/sprint1/app.jar
chown ec2-user:ec2-user /home/ec2-user/sprint1/app.jar
systemctl restart sprint1
sleep 10
systemctl is-active sprint1
curl --fail http://localhost:8080/health
```
処理：
```text
Current JAR Backup
      ↓
New JAR Download
      ↓
Temporary File
      ↓
app.jarへ置換
      ↓
Owner修正
      ↓
systemd Restart
      ↓
Process Active Check
      ↓
Local Health Check
```
`set -e`によって、途中のCommandが失敗した場合はScriptを継続しない構成とした。
---
# AWS Managed SSM Document ARN Failure
GitHub Actionsから最初に`ssm:SendCommand`を実行した際、AccessDeniedが発生した。
OIDCによるAWS Authentication自体は成功していた。
問題はIAM PolicyのSSM Document ARNだった。
誤った考え方：
```text
AWS-RunShellScriptのARNへ自分のAWS Account IDを含める
```
しかし`AWS-RunShellScript`はAWS Managed Documentである。
正しい形式：
```text
arn:aws:ssm:ap-northeast-1::document/AWS-RunShellScript
```
Account ID部分が空になる。
Policy修正後、GitHub ActionsからSendCommandが成功した。
ここで、
```text
OIDC成功
≠
すべてのAWS操作が許可される
```
ことを実際に確認した。
---
# First Automated CD Verification
Application Root Endpointを、
```text
Hello Sprint 3 v2!
```
から、
```text
Hello Sprint 3 CI/CD!
```
へ変更した。
その後、
```text
git commit
   ↓
git push
   ↓
GitHub Actions
   ↓
Build
   ↓
S3
   ↓
SSM Deployment
```
を実行した。
最初はEC2-Aのみが自動Deployment対象だった。
そのためALB経由でRequestすると、
```text
Hello Sprint 3 CI/CD!
Hello Sprint 3 v2!
```
の両方が返った。
これは、
```text
EC2-A = New Version
EC2-B = Old Version
```
というVersion Skewが発生しているため。
この結果から、複数Server環境では、
1台への自動Deploymentだけでは不十分であり、
全Nodeを安全な順番で更新する必要があることが明確になった。
---
# Automated Rolling Deployment Goal
Manual Rolling Deploymentで実施していた、
```text
Target Deregister
      ↓
Connection Draining
      ↓
Deploy
      ↓
Application Check
      ↓
Target Register
      ↓
Healthy Check
```
をGitHub Actionsへ移した。
重要なのは単にCommandを自動実行することではなく、
```text
どの順番ならServiceを止めずに更新できるか
```
という運用判断までWorkflowへ表現することだった。
---
# Build Before Deregistration
Rolling Deploymentでは、Targetを外す前にBuildを完了させる。
```text
Build
 ↓
JAR生成成功
 ↓
S3 Upload
 ↓
Target Deregister
```
という順番にした。
もし、
```text
Deregister
 ↓
Build
```
の順番にすると、Build FailureだけでALB配下のCapacityを減らしてしまう。
そのため、
```text
失敗しやすいBuildを先に完了
        ↓
Deployment可能なArtifactが存在することを確認
        ↓
Traffic Control開始
```
とした。
---
# Target Group ARN and Instance ID
Elastic Load Balancing APIでTargetを操作する際、
```text
Target Group ARN
```
と、
```text
EC2 Instance ID
```
を指定した。
意味：
```text
Target Group ARN
= どのTarget Groupを操作するか
Instance ID
= そのTarget Group内のどのEC2を操作するか
```
今回操作したTarget Group：
```text
sprint3-tg
```
EC2-A / EC2-BをそれぞれInstance IDで指定した。
ALB本体を直接Deregisterするのではなく、
ALBがForward先として使用するTarget GroupのRegistered Targetを操作する。
---
# Deregister Target in GitHub Actions
例：
```bash
aws elbv2 deregister-targets \
  --target-group-arn "<TARGET_GROUP_ARN>" \
  --targets Id=<INSTANCE_ID>
```
その直後に、
```bash
aws elbv2 wait target-deregistered \
  --target-group-arn "<TARGET_GROUP_ARN>" \
  --targets Id=<INSTANCE_ID>
```
を実行した。
意味：
```text
deregister-targets
→ Target Groupから外す
wait target-deregistered
→ 完全にDeregisterされるまで次へ進まない
```
単にDeregister APIを呼ぶだけではなく、
Connection Draining完了まで待つことをWorkflowへ組み込んだ。
---
# Register Target in GitHub Actions
Deployment後、TargetをTarget Groupへ戻した。
```bash
aws elbv2 register-targets \
  --target-group-arn "<TARGET_GROUP_ARN>" \
  --targets Id=<INSTANCE_ID>
```
さらに、
```bash
aws elbv2 wait target-in-service \
  --target-group-arn "<TARGET_GROUP_ARN>" \
  --targets Id=<INSTANCE_ID>
```
を実行した。
意味：
```text
register-targets
→ Target Groupへ戻す
target-in-service
→ ALBからHealthyと判定されるまで待つ
```
---
# Two Levels of Health Verification
Deployment後は2段階で正常性を確認した。
1つ目：
```bash
curl --fail http://localhost:8080/health
```
これはEC2自身からSpring BootへRequestする。
```text
EC2
 ↓ localhost
Spring Boot
```
Applicationが起動し、HTTP Responseを返せるかを確認する。
2つ目：
```text
aws elbv2 wait target-in-service
```
これは、
```text
ALB
 ↓
Target Group
 ↓
EC2
```
という経路でTargetがHealthyになったことを確認する。
したがって、
```text
Local Health Check
≠
ALB Health Check
```
である。
---
# Automated Rolling Deployment Order
今回の最終WorkflowではEC2-Bから更新し、
Bが完全に復帰した後でEC2-Aへ進むようにした。
```text
Maven Build
    ↓
JAR → S3
    ↓
EC2-B Deregister
    ↓
Wait target-deregistered
    ↓
EC2-B SSM Deploy
    ↓
Local /health OK
    ↓
EC2-B Register
    ↓
Wait target-in-service
    ↓
EC2-B Healthy
    ↓
EC2-A Deregister
    ↓
Wait target-deregistered
    ↓
EC2-A SSM Deploy
    ↓
Local /health OK
    ↓
EC2-A Register
    ↓
Wait target-in-service
    ↓
EC2-A Healthy
```
最も重要なのは、
```text
B Healthy
   ↓
A Deregister
```
という順番。
Bがまだ復帰していない状態でAもDeregisterすると、
ALB配下にHealthy Targetが存在しない時間が発生する可能性がある。
この順番をWorkflowで保証することで、
Deployment中も最低1台のTargetがServiceを提供できるようにした。
---
# GitHub Actions Step Order as Operations Logic
GitHub ActionsのStepは上から順番に実行される。
この性質によって、
```text
Bを安全に更新
      ↓
Bの復旧を確認
      ↓
Aを安全に更新
```
というOperation LogicそのものをYAMLへ記述できる。
つまり今回のCI/CDでは、
```text
Command Automation
```
だけではなく、
```text
Operational Decision Automation
```
まで行った。
---
# First Full Automated Rolling Deployment Result
Rolling Deployment用WorkflowをCommitし、Pushした。
その後GitHub Actionsが自動起動し、
EC2-B → EC2-Aの順番でDeploymentを実行した。
最終結果：
```text
Target Group: sprint3-tg
Total Targets : 2
Healthy       : 2
Unhealthy     : 0
Draining      : 0
```
EC2-A：
```text
Healthy
```
EC2-B：
```text
Healthy
```
となった。
これによって、
```text
git push
   ↓
CI
   ↓
Artifact
   ↓
CD
   ↓
Rolling Deployment
   ↓
ALB Healthy
```
までが自動で完走したことを確認した。
---
# Deployment Execution Time
初回のFull Automated Rolling Deploymentの所要時間：
```text
11 minutes 55 seconds
```
各Stepを確認すると、概ね次の時間だった。
```text
Maven Build                 : 17 sec
JAR Upload to S3            : 3 sec
EC2-B Deregister            : 5 min 06 sec
EC2-B SSM Deploy            : 19 sec
EC2-B Register / Healthy    : 17 sec
EC2-A Deregister            : 5 min 06 sec
EC2-A SSM Deploy            : 18 sec
EC2-A Register / Healthy    : 17 sec
Artifact Upload             : 2 sec
```
この結果から、
```text
EC2-B Deregister
+
EC2-A Deregister
```
だけで約10分12秒かかっていることが分かった。
全体11分55秒の大部分をDeregister待機が占めていた。
---
# Deregistration Delay Analysis
Target GroupのAttributeを確認した。
設定：
```text
Deregistration Delay
300 seconds
```
300秒 = 5分。
実測：
```text
EC2-B Deregister
約5分06秒
EC2-A Deregister
約5分06秒
```
とほぼ一致した。
したがって、今回Deploymentに約12分かかった主因は、
```text
EC2 Performance不足
```
ではなく、
```text
Target GroupのDeregistration Delay
```
だった。
---
# Performance vs Configuration
最初は、
```text
Deploymentが長い
      ↓
EC2のSpecが低い？
```
という可能性も考えた。
しかしStepごとの実測では、
```text
Build
約17秒
SSM Deploy
約18〜19秒
Register / Healthy
約17秒
```
程度だった。
一方、Deregisterは1台約5分。
このため、
```text
遅い
 ↓
Server Specを上げる
```
と即断するのではなく、
```text
どのStepが遅いか
      ↓
CPU処理なのか
Networkなのか
Application起動なのか
意図的なWaitなのか
      ↓
設定を確認
```
というPerformance Analysisが必要であることを確認した。
今回の場合は、
```text
Performance Problem
```
ではなく、
```text
Availability / Connection DrainingのためのDesign Setting
```
が主因だった。
---
# Why Deregistration Delay Exists
Deregistration Delayは単なる無駄な待機ではない。
Targetを外した瞬間に既存Connectionを強制終了すると、
処理中Requestへ影響する可能性がある。
そのため、
```text
Deregister Request
      ↓
Draining
      ↓
Existing Connectionを処理
      ↓
Delay終了
      ↓
Target Deregistered
```
という時間を確保する。
したがって、
```text
Deregistration Delayを短くする
= Deploymentを速くする
```
だけではなく、
```text
既存Requestへ与える影響
```
とのTrade-offとして設計する必要がある。
---
# Manual Deployment to Automated Deployment
Sprint 3本体では、
```text
Developer
 ↓
Maven Build
 ↓
SCP
 ↓
SSH
 ↓
systemctl
 ↓
Target Control
```
を人間が実行していた。
Sprint 3 Extension終了時点では、
```text
Developer
 ↓
git push
 ↓
GitHub Actions
 ↓
Build
 ↓
S3
 ↓
SSM
 ↓
Target Control
 ↓
Rolling Deployment
```
へ変化した。
人間が直接EC2へSSHしてDeploymentする必要がなくなった。
---
# What Was Automated
今回自動化した内容：
```text
Repository Checkout
Java Setup
Maven Build
JAR Creation
Artifact Save
AWS Authentication
JAR Upload to S3
Target Deregistration
Deregistration Wait
SSM Command Execution
JAR Backup
JAR Download
JAR Replacement
systemd Restart
Process Check
Local Health Check
Target Registration
ALB Healthy Wait
Second Node Deployment
```
つまり、
```text
Build Automation
+
Deployment Automation
+
Traffic Control Automation
+
Health Verification Automation
```
まで実施した。
---
# CI/CD Failure Boundary
今回のWorkflowでは、
前段の処理が失敗すると後続Stepへ進まないことが重要になる。
例：
```text
Build Failure
→ Targetを外さない
```
```text
EC2-B Deploy Failure
→ Bを正常Targetとして復帰できない
→ AのUpdateへ進まない
```
```text
B Healthy Wait Failure
→ A Deregisterへ進まない
```
これによって、失敗時にさらにAvailabilityを悪化させる操作を防ぐ。
---
# Current Limitation of Automated Rolling Deployment
今回のRolling Deploymentは、
学習目的として固定EC2-A / EC2-BのInstance IDをWorkflowへ指定している。
```text
EC2-A
fixed Instance ID
EC2-B
fixed Instance ID
```
これは固定2台構成では理解しやすいが、
Auto Scaling GroupではInstanceが交換されるため、
固定Instance IDを前提にはできない。
将来的には、
```text
Launch Template
      ↓
Auto Scaling Group
      ↓
Instance Refresh
```
や、
```text
AMI / Image Build
      ↓
Launch Template Version
      ↓
Instance Refresh
```
のような方式へ発展させる。
---
# Immutable Infrastructure Concept
今回の固定EC2では、
既存Server上のJARを置き換える方式を使用した。
```text
Existing EC2
   ↓
Replace JAR
   ↓
Restart
```
今後は、
```text
New Application Version
      ↓
New Image / New Launch Template
      ↓
New Instance
      ↓
Old Instance Replace
```
というImmutable Infrastructureの考え方も学習対象になる。
既存Serverを長期間変更し続けるのではなく、
新しいVersionを新しいInstanceとして作り直すことで、
Environment差分を減らす考え方である。
---
# Sprint 3 Extension Troubleshooting Examples
Extensionで経験した代表的な問題：
```text
GitHub Actions
./mvnw Permission denied
      ↓
Git File Mode確認
      ↓
100644
      ↓
git update-index --chmod=+x
      ↓
100755
```
```text
Auto Scaling EC2 Bootstrap Failure
      ↓
User Data確認
      ↓
dnf Package Conflict
      ↓
curl-minimal
      ↓
Install Command修正
```
```text
GitHub Actions
OIDC Authentication Success
      ↓
SSM SendCommand AccessDenied
      ↓
IAM Policy Resource確認
      ↓
AWS Managed Document ARN確認
      ↓
Account IDを含めないARNへ修正
```
```text
CI/CD Success
      ↓
ALB Responseが2 Version混在
      ↓
EC2-AのみDeployment済み
      ↓
EC2-BがOld Version
      ↓
Multi-node Rolling Deploymentが必要
```
```text
Rolling Deployment
11 min 55 sec
      ↓
Step Duration確認
      ↓
Deregisterが各5分超
      ↓
Target Group Attribute確認
      ↓
Deregistration Delay = 300 sec
```
---
# Expanded Troubleshooting Layers
Sprint 3本体までのLayerに、
ExtensionではさらにAutomation / Control PlaneのLayerが追加された。
```text
Git
 ↓
GitHub
 ↓
GitHub Actions
 ↓
OIDC
 ↓
STS
 ↓
IAM
 ↓
AWS API
 ↓
S3 / Systems Manager / ELB
 ↓
Target Group
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
JDBC
 ↓
RDS
 ↓
PostgreSQL
```
問題が発生した際は、
```text
Authentication Failureか
Authorization Failureか
AWS API Failureか
SSM Agentか
Linux Commandか
Applicationか
ALB Health Checkか
```
をLayerごとに切り分ける必要がある。
---
# Sprint 3 Extension Result
Sprint 3 Extensionでは以下を一通り経験した。
```text
CloudWatch Metrics
      ↓
RequestCount / CPUUtilization
      ↓
CloudWatch Alarm
      ↓
SNS Notification
      ↓
Launch Template
      ↓
User Data
      ↓
S3 Artifact
      ↓
Parameter Store SecureString
      ↓
IAM Role
      ↓
Auto Scaling Group
      ↓
Self Healing
      ↓
Target Tracking Scaling
      ↓
EC2 Purchase Options
      ↓
AWS WAF
      ↓
GitHub Actions CI
      ↓
Maven Wrapper Permission Fix
      ↓
JAR Artifact
      ↓
OIDC
      ↓
AWS STS
      ↓
GitHub Actions IAM Role
      ↓
Systems Manager
      ↓
S3 Based CD
      ↓
Automated EC2 Deployment
      ↓
Multi-node Version Skew Observation
      ↓
ELB Target Control
      ↓
Automated Rolling Deployment
      ↓
B Healthy Wait
      ↓
A Rolling Deployment
      ↓
A / B Healthy
      ↓
Execution Time Analysis
      ↓
Deregistration Delay 300 sec
      ↓
Bottleneck Identification
```
---
# Sprint 3 Final Learning Progress
Sprint 1では、
```text
Code
→ Build
→ JAR
→ EC2
→ Linux
→ Process
→ Port
→ HTTP
→ Network
```
Sprint 2では、
```text
Database
→ JDBC
→ SQL
→ Persistence
→ Authentication
```
Sprint 3本体では、
```text
systemd
→ Multi-AZ
→ ALB
→ Target Group
→ Health Check
→ Availability
→ Failure Testing
→ Manual Rolling Deployment
→ Rollback
```
Sprint 3 Extensionでは、
```text
Monitoring
→ Alerting
→ Auto Scaling
→ Self Healing
→ Security
→ IAM
→ CI
→ CD
→ OIDC
→ Systems Manager
→ Automated Rolling Deployment
→ Performance Analysis
```
まで追加した。
最終的に、
```text
Code
 ↓
Git
 ↓
GitHub
 ↓
CI
 ↓
Build
 ↓
Artifact
 ↓
AWS Authentication
 ↓
CD
 ↓
Traffic Control
 ↓
EC2
 ↓
Process
 ↓
Application
 ↓
Database
 ↓
Monitoring
```
という開発から運用までの一連の流れを実際に構築・観測した。
---
# Next Step - Infrastructure as Code
Sprint 3終了時点では、
Application Deploymentは大きく自動化できた。
一方、
```text
VPC
Subnet
Route Table
Security Group
ALB
Target Group
EC2
IAM
Auto Scaling
CloudWatch
```
などのInfrastructure Resourceは、
まだAWS Console中心で作成した部分が多い。
次の段階ではTerraformを利用し、
```text
Infrastructure
      ↓
Code
      ↓
Git
      ↓
Version Control
      ↓
Plan
      ↓
Apply
```
というInfrastructure as Codeへ進む。
Sprint 3で、
```text
Application Deployment
```
を自動化した次に、
```text
Infrastructure Provisioning
```
そのものを自動化する。
最終的には、
```text
Infrastructure as Code
        ↓
CI/CD
        ↓
Automated Deployment
        ↓
Monitoring
        ↓
Troubleshooting
```
を一連のDevOps Workflowとして扱える状態を目指す。