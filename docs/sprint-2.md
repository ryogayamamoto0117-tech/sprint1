# Sprint 2 - Spring Boot × RDS PostgreSQL

Sprint 1でAWS EC2上にデプロイしたSpring Bootアプリケーションに、
Amazon RDS for PostgreSQLを追加した。

Sprint 2では、単にDBへ接続するだけではなく、

```text
HTTP Request
    ↓
Spring Boot
    ↓
Java Object
    ↓
JDBC
    ↓
SQL
    ↓
RDS PostgreSQL
```

というWebアプリケーションからデータベースまでの一連の流れを、
実際に構築・観測することを目的とした。

また、意図的なDB認証障害や文字コード問題を発生させ、
ログや通信経路を確認しながら原因を切り分けた。

---

## Sprint 2 Goal

学習内容を保存できる簡単なAPIを作成する。

実装するAPI：

```text
POST /records
→ 学習記録をRDS PostgreSQLへ保存

GET /records
→ RDS PostgreSQLから学習記録を取得
```

保存するデータ：

```text
id
topic
memo
```

例：

```json
{
  "topic": "Linux",
  "memo": "lsコマンドを学習"
}
```

---

# Architecture

Sprint 2では以下の構成を作成した。

```text
Windows PC
    │
    │ HTTP
    │ TCP 8080
    ▼
Internet
    │
    ▼
Internet Gateway
    │
    ▼
VPC
10.1.0.0/16
    │
    ├── Public Subnet
    │     10.1.1.0/24
    │
    │     EC2
    │     Spring Boot
    │     TCP 8080
    │
    │          │
    │          │ JDBC / PostgreSQL
    │          │ TCP 5432
    │          ▼
    │
    ├── Private Subnet A
    │     10.1.2.0/24
    │     ap-northeast-1a
    │
    └── Private Subnet C
          10.1.3.0/24
          ap-northeast-1c

              ↓

        RDS PostgreSQL
        Public Access: No
```

通信経路は大きく2つに分かれる。

```text
Windows PC
    ↓ HTTP :8080
EC2 / Spring Boot
```

と、

```text
EC2 / Spring Boot
    ↓ PostgreSQL :5432
RDS PostgreSQL
```

8080と5432は、それぞれ異なる通信で使用される。

---

# RDS Network Design

RDSをインターネットへ直接公開せず、
EC2からのみ接続できる構成にした。

Private Subnet：

```text
sprint2-private-subnet-a
10.1.2.0/24
ap-northeast-1a
```

```text
sprint2-private-subnet-c
10.1.3.0/24
ap-northeast-1c
```

どちらのSubnetもInternet GatewayへのDefault Routeを持たない。

```text
10.1.0.0/16 → local
```

そのため、RDSはインターネットから直接アクセスする構成にはしていない。

---

## DB Subnet Group

RDS用としてDB Subnet Groupを作成した。

```text
sprint2-db-subnet-group
```

登録したSubnet：

```text
Private Subnet A
ap-northeast-1a

Private Subnet C
ap-northeast-1c
```

RDSではDB Subnet Groupに複数AZのSubnetを登録する。

ただし、

```text
DB Subnet Groupに複数AZを登録
```

したことと、

```text
RDS自体をMulti-AZ構成にする
```

ことは別。

今回はDB Subnet Groupには複数AZを登録したが、
RDS PostgreSQL自体はSingle-AZとして構築した。

---

# Security Group

RDS用Security Groupを作成した。

```text
sprint2-rds-sg
```

Inbound Rule：

```text
PostgreSQL
TCP 5432
Source:
EC2 Security Group
```

IPアドレスを直接指定するのではなく、

```text
EC2 Security Group
    ↓
RDS Security Group
```

というSecurity Group間の許可を設定した。

これによって、

```text
Internet
→ RDS
```

は許可せず、

```text
EC2
→ RDS :5432
```

だけを許可した。

---

# RDS PostgreSQL

Amazon RDS for PostgreSQLを作成した。

主な構成：

```text
Engine:
PostgreSQL

Deployment:
Single-AZ

Public Access:
No

Port:
5432

Database:
sprint2db
```

RDSのEndpointはSpring BootやpsqlからDBへ接続する際に使用する。

```text
RDS Endpoint
        ↓
DNS
        ↓
RDS PostgreSQL
```

---

# PostgreSQL Client

まずJavaから接続する前に、
EC2から直接RDSへ接続できることを確認した。

EC2へPostgreSQL Clientをインストール。

```bash
sudo dnf install -y postgresql18
```

RDSへ接続：

```bash
psql \
  -h <RDS_ENDPOINT> \
  -p 5432 \
  -U postgres \
  -d sprint2db
```

各Option：

```text
-h
= host
→ 接続するDBサーバー

-p
= port
→ PostgreSQLのPort

-U
= user
→ DBへログインするUser

-d
= database
→ 使用するDatabase
```

接続できると、

```text
sprint2db=>
```

となる。

これによって、

```text
EC2
 ↓
TCP 5432
 ↓
RDS Security Group
 ↓
PostgreSQL
 ↓
Authentication
```

が正常に動作していることを確認した。

---

# Database / Table

学習記録を保存する`records` Tableを作成した。

```sql
CREATE TABLE records (
    id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    topic VARCHAR(100) NOT NULL,
    memo VARCHAR(500) NOT NULL
);
```

構造：

```text
records
├── id
├── topic
└── memo
```

役割：

```text
id
→ 各Recordを一意に識別するPrimary Key

topic
→ 学習テーマ

memo
→ 学習内容
```

`id`にはIDENTITYを使用したため、
INSERT時に自分で値を指定しなくてもPostgreSQLが自動生成する。

---

# SQL

まずpsqlから直接INSERTとSELECTを実行した。

INSERT：

```sql
INSERT INTO records (topic, memo)
VALUES ('AWS CLI', 'CLIからAPIを呼び出した');
```

SELECT：

```sql
SELECT id, topic, memo
FROM records;
```

これによって、

```text
SQL
 ↓
PostgreSQL
 ↓
records Table
```

が正常に動作していることを確認した。

---

# CRUD

Database操作の基本であるCRUDについても確認した。

```text
Create
→ INSERT

Read
→ SELECT

Update
→ UPDATE

Delete
→ DELETE
```

Sprint 2では、

```text
INSERT
SELECT
UPDATE
```

を実際に使用した。

文字化けしたRecordを修正する際には、

```sql
UPDATE records
SET memo = 'lsコマンドを学習'
WHERE id = 2;
```

を実行した。

---

# JDBC

JavaからPostgreSQLへ接続するためにJDBCを使用した。

JDBC：

```text
Java Database Connectivity
```

JavaからRelational Databaseへ接続するための標準的なInterface。

今回の構成：

```text
Spring Boot
    ↓
JdbcTemplate
    ↓
JDBC
    ↓
PostgreSQL JDBC Driver
    ↓
PostgreSQL
```

---

# Maven Dependencies

`pom.xml`へ以下を追加した。

```xml
<dependency>
    <groupId>org.springframework.boot</groupId>
    <artifactId>spring-boot-starter-jdbc</artifactId>
</dependency>

<dependency>
    <groupId>org.postgresql</groupId>
    <artifactId>postgresql</artifactId>
    <scope>runtime</scope>
</dependency>
```

役割：

```text
spring-boot-starter-jdbc
→ Spring BootでJDBCを利用するための機能

postgresql
→ PostgreSQLへ接続するJDBC Driver
```

---

# DataSource Configuration

`application.properties`へDB接続情報を設定した。

```properties
spring.datasource.url=jdbc:postgresql://<RDS_ENDPOINT>:5432/sprint2db
spring.datasource.username=postgres
spring.datasource.password=${DB_PASSWORD}
spring.datasource.driver-class-name=org.postgresql.Driver
```

Passwordは直接ファイルへ記述せず、

```text
${DB_PASSWORD}
```

としてLinuxのEnvironment Variableから取得する。

EC2上では、

```bash
export DB_PASSWORD='RDS_PASSWORD'
```

として設定した。

構造：

```text
Linux Environment Variable
DB_PASSWORD
        ↓
Spring Boot
        ↓
application.properties
        ↓
JDBC
        ↓
PostgreSQL Authentication
```

PasswordをSource Codeへ直接記述しないことで、
GitHubへCredentialをCommitすることを防ぐ。

---

# Record Class

DatabaseのRecordをJava上で扱うために、
`Record` Classを作成した。

```java
public class Record {

    private Long id;
    private String topic;
    private String memo;

    // Getter / Setter
}
```

Databaseとの対応：

```text
Java Class
Record
        ↓

Database Table
records
```

さらに、

```text
Record.id
↔ records.id

Record.topic
↔ records.topic

Record.memo
↔ records.memo
```

という対応になる。

重要なのは、

```text
Class
= データ構造の設計

Object
= Classから生成された実際の値

DB Row
= Table内の1件のデータ
```

という違い。

今回、

```text
1つのRecord Object
≈
records Tableの1 Row
```

として扱った。

---

# POST /records

学習記録を保存するAPIを実装した。

```java
@PostMapping("/records")
public String createRecord(@RequestBody Record record) {

    jdbcTemplate.update(
        "INSERT INTO records (topic, memo) VALUES (?, ?)",
        record.getTopic(),
        record.getMemo()
    );

    return "saved";
}
```

通信の流れ：

```text
Windows
    ↓
HTTP POST
    ↓
JSON
    ↓
Spring Boot
    ↓
@RequestBody
    ↓
Record Object
    ↓
JdbcTemplate
    ↓
INSERT
    ↓
PostgreSQL
    ↓
records Table
```

例：

```json
{
  "topic": "Java",
  "memo": "テストです"
}
```

このJSONがSpring Bootによって、

```text
Record Object
```

へ変換される。

---

# @RequestBody

`@RequestBody`によって、
HTTP Request BodyのJSONをJava Objectへ変換する。

```text
HTTP Request

{
  "topic": "Java",
  "memo": "テストです"
}

        ↓

@RequestBody

        ↓

Record Object

topic = "Java"
memo = "テストです"
```

HTTPそのものがJSONなのではなく、

```text
HTTP
└── Request Body
      └── JSON
```

という関係。

JSONはHTTP Bodyで使用できるデータ形式の1つ。

---

# SQL Placeholder

INSERTでは、

```sql
VALUES (?, ?)
```

を使用した。

```text
?
```

へ、

```java
record.getTopic()
record.getMemo()
```

の値が渡される。

SQL構造と入力値を分離して扱うことで、
入力値がそのままSQL構造として解釈されることを防ぐ基本的な仕組みになる。

---

# GET /records

RDSから学習記録を取得するAPIを実装した。

```java
@GetMapping("/records")
public List<Record> getRecords() {

    return jdbcTemplate.query(
        "SELECT id, topic, memo FROM records ORDER BY id DESC",

        (rs, rowNum) -> {

            Record record = new Record();

            record.setId(rs.getLong("id"));
            record.setTopic(rs.getString("topic"));
            record.setMemo(rs.getString("memo"));

            return record;
        }
    );
}
```

処理の流れ：

```text
HTTP GET /records
        ↓
Spring Boot
        ↓
JdbcTemplate
        ↓
SELECT
        ↓
PostgreSQL
        ↓
ResultSet
        ↓
Record Object
        ↓
List<Record>
        ↓
JSON
        ↓
HTTP Response
```

---

# ResultSet

JDBCでSELECTした結果はResultSetとして取得される。

イメージ：

```text
PostgreSQL

id | topic | memo
------------------------------
1  | AWS   | ...
2  | Linux | ...
3  | Java  | ...

        ↓

ResultSet

        ↓

1 Rowずつ処理

        ↓

Record Object

        ↓

List<Record>
```

今回のLambda式、

```java
(rs, rowNum) -> {
```

では、
ResultSetの1 Rowを1つのRecord Objectへ変換している。

---

# JSON Response

`List<Record>`をControllerからreturnすると、
Spring BootによってJSONへ変換される。

```text
List<Record>
    ↓
Spring Boot / JSON Serialization
    ↓
JSON
    ↓
HTTP Response
```

取得結果の例：

```json
[
  {
    "id": 3,
    "topic": "Java",
    "memo": "テストです"
  },
  {
    "id": 2,
    "topic": "Linux",
    "memo": "lsコマンドを学習"
  },
  {
    "id": 1,
    "topic": "AWS CLI",
    "memo": "CLIからAPIを呼び出した"
  }
]
```

---

# API Check from Windows

Windows PowerShellからEC2へHTTP Requestを送った。

```powershell
curl.exe http://<EC2_PUBLIC_IP>:8080/records
```

このURLは、

```text
http://
→ HTTPを使用

<EC2_PUBLIC_IP>
→ 接続するServer

:8080
→ EC2上でSpring BootがLISTENしているPort

/records
→ Spring BootのEndpoint
```

という意味。

通信経路：

```text
Windows
    ↓
EC2 Public IP
    ↓
TCP 8080
    ↓
Spring Boot
    ↓
GET /records
    ↓
JdbcTemplate
    ↓
RDS :5432
```

---

# Character Encoding Troubleshooting

POST / GETの動作確認中に日本語の文字化けが発生した。

最初にWindows PowerShellの`Invoke-RestMethod`を使用して
日本語をPOSTしたところ、

```text
ls???????
```

としてRDSへ保存された。

一方、以前psqlから登録した日本語データはRDS上で正常だった。

PostgreSQLのEncodingを確認：

```sql
SHOW server_encoding;
```

```text
UTF8
```

```sql
SHOW client_encoding;
```

```text
UTF8
```

Database自体はUTF-8を使用していた。

---

## GET Encoding Check

`Invoke-WebRequest`では、

```text
CLIã...
```

のような文字化けが発生した。

しかし、

```powershell
curl.exe -i http://<EC2_PUBLIC_IP>:8080/records
```

では、

```json
{
  "memo": "CLIからAPIを呼び出した"
}
```

と正常に表示された。

この結果から、

```text
PostgreSQL
    ↓
JDBC
    ↓
Spring Boot
    ↓
HTTP Response
```

までは正常であり、

Windows PowerShell側のResponse文字コード解釈によって
表示が崩れていたことを切り分けた。

---

## POST Encoding Check

UTF-8でJSONファイルを作成し、

```powershell
curl.exe -i `
  -X POST `
  http://<EC2_PUBLIC_IP>:8080/records `
  -H "Content-Type: application/json; charset=UTF-8" `
  --data-binary "@test.json"
```

でPOSTした。

結果：

```text
saved
```

その後GETすると、

```json
{
  "topic": "Java",
  "memo": "テストです"
}
```

として正常に保存されていることを確認した。

このことから、

```text
Spring Boot
→ JDBC
→ PostgreSQL
```

の日本語処理は正常であり、
最初の文字化けはPowerShellからPOSTした際のEncodingが原因であることを切り分けた。

---

# Persistence

Spring BootのJava Processを一度停止した。

```text
Ctrl + C
```

その後、再び起動。

```bash
java -jar app.jar
```

GET APIを実行すると、
以前登録したRecordがすべて残っていた。

```text
Old Java Process
    ↓
STOP
    X

RDS
records
    ↓
Data remains
    ↓

New Java Process
    ↓
RDSへ再接続
    ↓
以前のDataを取得
```

これによって、

```text
Application Process
```

と、

```text
Persistent Data
```

が分離されていることを確認した。

Spring Bootが停止しても、
RDSへ保存したデータは残る。

これがDatabaseによるPersistenceの役割の1つ。

---

# Change Application Behavior

GET APIの並び順を変更した。

変更前：

```sql
ORDER BY id
```

結果：

```text
1
2
3
```

変更後：

```sql
ORDER BY id DESC
```

結果：

```text
3
2
1
```

`DESC`はDescending。

降順を意味する。

DatabaseのData自体を書き換えたわけではなく、
SELECT時の取得順序だけを変更した。

---

# Manual Redeployment

Codeを変更したあと、
再びEC2へDeploymentした。

流れ：

```text
Code Change
    ↓
Test
    ↓
Maven Package
    ↓
JAR
    ↓
SCP
    ↓
EC2
    ↓
Spring Boot Restart
    ↓
curl
    ↓
Verification
```

Test：

```powershell
.\mvnw.cmd test
```

Build：

```powershell
.\mvnw.cmd package
```

JAR転送：

```powershell
scp -i "path/to/key.pem" `
  ".\target\sprint1-0.0.1-SNAPSHOT.jar" `
  ec2-user@<EC2_PUBLIC_IP>:~/sprint1/app.jar
```

EC2で起動：

```bash
java -jar app.jar
```

確認：

```powershell
curl.exe http://<EC2_PUBLIC_IP>:8080/records
```

結果：

```text
id=3
id=2
id=1
```

となり、
変更後のApplicationがEC2へ反映されたことを確認した。

---

# Why CI/CD is Needed

今回のManual Deploymentでは、
毎回ほぼ同じ操作を行った。

```text
Test
↓
Build
↓
JAR
↓
Transfer
↓
Stop
↓
Start
↓
Verify
```

この作業を人間が毎回実行すると、

```text
Testを忘れる

古いJARを転送する

SCPを忘れる

Restartを忘れる

確認を忘れる
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
Deploy
    ↓
Verification
```

を自動化するCI/CDへ発展させる。

Sprint 2では、
CI/CDで何を自動化するのかを理解するために、
まずManual Deploymentを実際に経験した。

---

# Database Authentication Failure

DB Passwordを意図的に間違えて、
障害時のログを確認した。

```bash
export DB_PASSWORD='wrong-password'
```

その状態でSpring Bootを起動し、

```text
GET /records
```

を実行。

HTTP Response：

```text
500 Internal Server Error
```

重要なのは、

```text
HTTP 500
```

が返っているため、

```text
EC2
Spring Boot
TCP 8080
HTTP
```

までは正常に動作しているということ。

Application Logでは、

```text
CannotGetJdbcConnectionException
```

を確認した。

さらにException Chainを追うと、

```text
org.postgresql.util.PSQLException:
FATAL: password authentication failed for user "postgres"
```

を確認した。

---

# Exception / Caused by

Javaでは、
あるExceptionが別のExceptionを原因として持つことがある。

イメージ：

```text
Request Processing Error
        ↓
CannotGetJdbcConnectionException
        ↓
Caused by
        ↓
PSQLException
        ↓
password authentication failed
```

`Caused by`がある場合は、
Exception Chainをより深く追うことでRoot Causeを確認できる。

ただし、すべてのExceptionに必ず`Caused by`が存在するわけではない。

今回、

```text
password authentication failed
```

まで確認できたことで、

```text
EC2
↓
Network
↓
RDS :5432
↓
PostgreSQL
```

までは到達しており、

```text
Authentication
```

の段階で失敗していると判断できた。

---

# Error Layer Troubleshooting

Database接続障害について、
Error Messageから失敗しているLayerを切り分ける。

```text
Connection timed out
        ↓
Network
Security Group
Route
Port
などを疑う
```

```text
password authentication failed
        ↓
PostgreSQLまで到達済み
        ↓
Username / Password
Authenticationを疑う
```

```text
SQL syntax error
        ↓
DB Connection成功
Authentication成功
        ↓
SQL自体を疑う
```

問題が起きたときに、

```text
DBにつながらない
```

だけで考えるのではなく、

```text
① Server
② Process
③ Port
④ Network
⑤ DB Server
⑥ Authentication
⑦ SQL
```

とLayerを分けて考える。

---

# Sprint 1 TroubleshootingとのConnection

Sprint 1では、

```text
Process
↓
Port
↓
HTTP
↓
Network
```

を確認した。

Sprint 2では、
さらにその先へ進んだ。

```text
Process
↓
Port
↓
HTTP
↓
Network
↓
Spring Boot
↓
JDBC
↓
DB Network
↓
PostgreSQL
↓
Authentication
↓
SQL
```

ApplicationからDatabaseまで含めて、
より広い範囲のTroubleshootingを経験した。

---

# RDS PostgreSQL vs Aurora PostgreSQL

Sprint 2ではRDS PostgreSQLを実際に構築した。

その上でAurora PostgreSQLとの違いを整理した。

共通点：

```text
RDS PostgreSQL
Aurora PostgreSQL
```

どちらもAWSのManaged Relational Databaseとして利用できる。

Aurora PostgreSQLはPostgreSQL CompatibleなDatabase Engine。

---

## Aurora Storage

AuroraではStorageが複数AZに分散される。

イメージ：

```text
AZ-A
● ●

AZ-B
● ●

AZ-C
● ●
```

3つのAvailability Zoneへ、
合計6つのStorage Copyを持つ構成。

そのため、
Storage Layer自体が高可用性を意識した設計になっている。

---

## Aurora Writer / Reader

Auroraでは、

```text
Writer
```

と、

```text
Reader
```

を使用できる。

```text
                Writer
                  │
          ┌───────┼───────┐
        Reader  Reader  Reader
```

Readerは主に、

```text
Read Scaling
```

と、

```text
Failover
```

に利用できる。

Readerを複数配置することで、
SELECTなどの読み取り処理を分散できる。

---

## Aurora Auto Scaling

AuroraではReader数を負荷に応じて増減させることができる。

```text
Read Load Increase
        ↓
Reader Increase

Read Load Decrease
        ↓
Reader Decrease
```

Storage CapacityのScalingと、
ReaderによるRead PerformanceのScalingは別の概念として考える。

---

## Multi-AZ and Multi-Region

Availability ZoneとRegionは区別する。

```text
Multi-AZ
→ 同じRegion内
```

```text
Multi-Region
→ 複数Region
```

Aurora Global Databaseを使用すると、
複数RegionへDatabaseを展開できる。

例：

```text
Tokyo Region
Primary

        ↓

Another Region
Secondary
```

これは同一Region内のMulti-AZとは異なる。

---

# Sprint 2 Result

Sprint 2では以下の流れを一通り経験した。

```text
RDS Network Design
        ↓
Private Subnet
        ↓
DB Subnet Group
        ↓
RDS Security Group
        ↓
RDS PostgreSQL
        ↓
psql
        ↓
Database / Table
        ↓
SQL
        ↓
JDBC
        ↓
PostgreSQL Driver
        ↓
Spring Boot
        ↓
Record Class
        ↓
POST /records
        ↓
JSON → Java Object
        ↓
INSERT
        ↓
GET /records
        ↓
SELECT
        ↓
ResultSet
        ↓
Java Object
        ↓
JSON Response
        ↓
Persistence
        ↓
Code Change
        ↓
Test / Build
        ↓
Manual Deployment
        ↓
Intentional Failure
        ↓
Log / Exception Analysis
        ↓
Recovery
```

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

Sprint 2ではその先に、

```text
Database
→ JDBC
→ SQL
→ Persistence
→ Authentication
```

を追加した。

結果として、

```text
Client
    ↓
HTTP
    ↓
EC2
    ↓
Linux
    ↓
Java Process
    ↓
Spring Boot
    ↓
Controller
    ↓
Java Object
    ↓
JDBC
    ↓
TCP 5432
    ↓
RDS
    ↓
PostgreSQL
    ↓
Table
    ↓
Persistent Data
```

という、
Web ApplicationからDatabaseまでの一連の構造を
実際に構築・観測・障害復旧した。

またManual Deploymentを複数回行ったことで、
今後CI/CDによって自動化する対象も具体的に理解した。

Sprint 2を通して、

**HTTP → Application → JDBC → Network → Database → Authentication → SQL**

というLayerごとの考え方を身につけ、
問題発生時に一度にすべてを疑うのではなく、
通信経路とLogを使って原因を段階的に切り分けることを学んだ。