# sprint1

Spring Bootを使った学習用のWebアプリケーション作成。

## Purpose

Java / Spring Boot / Git / Maven / AWS / Linux / DevOpsをそれぞれ使用して
1つのアプリケーションを育てながら学習する。


## Tech Stack

- Java 17
- Spring Boot 4.1.1
- Maven
- Git / GitHub


# Endpoints

- `GET /`
  - `Hello Sprint 1!`

- `GET /health`
  - `200 OK`
  - Body: `OK`


  ## Test

```powershell
.\mvnw.cwd test
```

MockMvcを使用して`/health`の以下を確認する。

- HTTP Status: 200
- Response Body: OK


## Build

```powershell
.\mvnw.cwd package
```

Mavenを使用してテストを実行し、実行可能なJARファイルを生成する。

生成されたJAR:

```text
target\sprint1-0.0.1-SNAPSHOT.jar
```


## Run

```powershell
java -jar target\sprint1-0.0.1-SNAPSHOT.jar
```

アプリケーション起動後、以下のコマンドで動作確認する。

```powershell
curl.exe -i http://localhost:8080/health
```

正常時:

```text
HTTP/1.1 200
...
OK
```


## AWS Deployment

ローカル環境で作成・テスト・BuildしたSpring Bootアプリケーションを、AWS EC2へデプロイした。
今回の目的は、単にAWS上でアプリケーションを起動するだけではなく、


```text
JAR
↓
EC2
↓
Linux
↓
Java Process
↓
TCP Port
↓
HTTP
```

というアプリケーション実行時の流れを実際に確認すること。

---

### AWS Architecture

Sprint 1用として以下のAWS環境を構築した。

```text
Internet
   ↓
Internet Gateway
   ↓
VPC
10.1.0.0/16
   ↓
Public Subnet
10.1.1.0/24
   ↓
Security Group
22 / 8080
   ↓
EC2
Amazon Linux 2023
```

主な構成：

- VPC：`10.1.0.0/16`
- Public Subnet：`10.1.1.0/24`
- Internet Gateway
- Route Table
- Security Group
- EC2：Amazon Linux 2023 / t3.micro

Route Tableには以下を設定した。

```text
10.1.0.0/16 → local
0.0.0.0/0 → Internet Gatway
```

Security Groupでは、自分のIPアドレスから以下の通信を許可した。


```text
TCP 22
→ SSH接続

TCP 8080
→ Spring BootへのHTTPアクセス
```

Public Subnetは名前によってPublicになるのではなく、Internet GatewayへのRouteを持つことでインターネットとの通信経路を持つ。

---

## SSH Connection

Windows PowerShellからSSHでEC2へ接続した。

```powershell
ssh -i "path/to/key.pem" ec2-user@<EC2_PUBLIC_IP>
```

SSHは`Secure Shell`

ネットワーク越しにEC2へログインし、Linuxをリモート操作するために使用した。

接続前：

```text
PS C:\Users\...>
```

接続後：

```text
[ec2-user@ip-10-1-1-xxx ~]$
```

SSH接続後は、WindowsではなくEC2上のAmazon Linuxコマンドが実行される。

---

## Linux Environment Setup

EC2へ接続後、Javaの有無を確認した。

```bash
java -version
```

Javaがインストールされていなかったため、Amazon Corretto 17をインストールした。

```bash
sudo dnf install -y java-17-amazon-corretto-headless
```

インストール後、

```bash
java -version
```

でJava 17が使用できることを確認した。

アプリケーション配置用のディレクトリも作成した。

```bash
mkdir -p ~/sprint1
cd ~/sprint1
pwd
ls -la
```

今回使用した主なLinuxコマンド：

```text
pwd
= print working directory
→ 現在のディレクトリを確認

cd
= change directory
→ ディレクトリを移動

mkdir
= make directory
→ ディレクトリを作成

ls
= list
→ ファイルやディレクトリを確認
```

Linuxコマンドは、必要になったタイミングで正式名称・オプション・用途まで確認しながら学習する。


---

## Deploy JAR to EC2

ローカル環境でmavenによって生成したJARを、SPCでEC2へ転送した。

ローカル側のJAR：

```text
target/sprint1-0.0.1-SNAPSHOT.jar
```

転送先：

```text
~/sprint1/app.jar
```

Windows Powershellから実行：


```powershell
scp -i "path/to/key.pem" `
  ".\target\sprint1-0.0.1-SNAPSHOT.jar" `
  ec2-user@<EC2_PUBLIC_IP>:~/sprint1/app.jar
```

`scp` は `Secure Copy`。

SSHを利用して、ローカルPCとEC2の間で安全にファイルを転送する。


---

## Run Spring Boot on Amazon Linux

EC2上でJARを実行した。

```bash
cd ~/sprint1
java -jar app.jar
```

Spring Bootが起動し、TCP 8080でHTTPリクエストを受け付ける状態になった。

ローカルWindowsで動作していたものと同じJARをAmazon Linuxでも起動できた。

```text
Windows
   ↓
Java 17
   ↓
app.jar
   ↓
Spring Boot

同じJAR

Amazon Linux
   ↓
Java 17
   ↓
app.jar
   ↓
Spring Boot
```

JavaではコンパイルされたバイトコードをJVM(Java Virtual Machine)が実行するため、JVMが利用できる環境であれば同じJavaアプリケーションを異なるOS上で動かしやすい。


---

# HTTP Check from EC2

EC2内部からSpring BootへHTTPリクエストを送った。

```bash
curl -i http://localhost:8080/
```

```bash
curl -i http://localhost:8080/health
```

結果：

```text
GET /
→ HTTP 200
→ Hello Sprint 1!

GET /health
→ HTTP 200
→ OK
```

`localhost` を使用しているため、この通信はEC2内部で完結している。

```text
EC2
┌──────────────────────┐
│ curl                 │
│   ↓                  │
│ localhost:8080       │
│   ↓                  │
│ Spring Boot          │
└──────────────────────┘
```

これによって、EC2上のSpring Boot自体が正常にHTTPリクエストを処理できることを確認した。


---

## HTTP Check from Local PC

次にWindows PCから、EC2のPublic IPv4へHTTPリクエストを送った。

```powershell
curl.exe -i http://<EC2_PUBLIC_IP>:8080/
```

```powershell
curl.exe -i http://<EC2_PUBLIC_IP>:8080/health
```

両方でHTTP 200を確認した。

通信経路：

```text
Windows PC
    ↓
Internet
    ↓
Internet Gateway
    ↓
VPC / Subnet
    ↓
EC2
    ↓
Security Group
    ↓
TCP 8080
    ↓
Spring Boot
```

これによって、EC2内部だけでなく外部PCからもSpring Bootへアクセスできることを確認した。


---

## Process Check

Spring BootがLinux上でどのように動いているか確認した。

```bash
ps -ef | grep '[j]ava'
```

実行結果の例：

```text
ec2-user  ...  java -jar app.jar
```

`ps` は `Process Status`。

Linux上で動いているプロセスを確認するために使用する。

Spring Bootは、

```text
java -jar app.jar
```

というJavaプロセスとしてLinux上で動いていることを確認した。

各プロセスには、

```text
PID
= Process ID
```

が割り当てられる。


---

## Port Check

Javaプロセスが実際にTCP 8080を使用していることを確認した。

```bash
sudo ss -ltnp | grep 8080
```

結果の例：

```text
LISTEN ... *:8080 ... users:(("java",pid=...,fd=...))
```

`ss` はSocketの状態を確認するコマンド。

今回使用したオプション：

```text
-l
= listening
→ LISTEN中のSocket

-t
= TCP
→ TCPのみ

-n
= numeric
→ Portなどを数値表示

-p
= process
→ 使用しているProcessも表示
```

これによって、

```text
Java Process
    ↓
TCP 8080
    ↓
LISTEN
```

していることを確認した。



---

## Process / Port / HTTP

今回の確認によって、以下の役割の違いを理解した。

```text
ps
↓
Processは動いているか？

ss
↓
PortはLISTENしているか？

curl
↓
HTTPとして正常に応答するか？
```

Spring BootへのHTTP通信は、

```text
java -jar app.jar
        ↓
Java Process
        ↓
TCP 8080 LISTEN
        ↓
HTTP Request
        ↓
Spring Boot
        ↓
Controller
        ↓
HTTP Response
```

という流れで処理される。


---

## Failure Test

正常動作だけではなく、意図的にSpring Bootを停止して状態の変化を確認した。

`java -jar app.jar` を実行しているTerminalで、

```text
Ctrl + C
```

を実行。

Javaプロセスを停止させた。

その後、

```bash
ps -ef | grep '[j]ava'
```

を実行するとJavaプロセスが表示されなくなった。

```bash
sudo ss -ltnp | grep 8080
```

でも8080をLISTENしているプロセスが表示されなくなった。

さらに、

```bash
curl -i http://localhost:8080/health
```

を実行すると、

```text
curl: (7) Failed to connect to localhost:8080
Could not connect to server
```

となった。

因果関係：

```text
Java Process停止
        ↓
TCP 8080 LISTEN停止
        ↓
TCP接続不可
        ↓
HTTP通信不可
```

---

## Recovery Test

再び、

```bash
cd ~/sprint1
java -jar app.jar
```

を実行してSpring Bootを起動した。

その後、

```bash
ps -ef | grep '[j]ava'
```

```bash
sudo ss -ltnp | grep 8080
```

```bash
curl -i http://localhost:8080/health
```

を順番に確認。

```text
Java Process
→ 復活

TCP 8080 LISTEN
→ 復活

HTTP
→ 200 OK
```

となり、アプリケーションが復旧したことを確認した。

---

## Troubleshooting Flow

今回のSprintで、Webアプリケーションへ接続できない場合の基本的な切り分け方法を学んだ。

```text
Webアプリにつながらない
        ↓
① Process
   ps
   Javaは動いている？
        ↓
② Port
   ss
   8080はLISTENしている？
        ↓
③ HTTP
   curl localhost
   EC2内部からHTTP応答する？
        ↓
④ Network
   EC2内部では成功するが
   外部PCから失敗する？
        ↓
Security Group
Public IP
Route Table
Internet Gateway
などを確認
```

問題が発生したときに、すべてを一度に疑うのではなく、

```text
Process
↓
Port
↓
HTTP
↓
Network
```

と層を分けて原因を特定する。

---

## Sprint 1 Result

Sprint 1では以下の流れを一通り経験した。

```text
Local Spring Boot Development
        ↓
Maven Build
        ↓
JAR
        ↓
Git / GitHub
        ↓
AWS VPC / Subnet
        ↓
Internet Gateway / Route Table
        ↓
Security Group
        ↓
EC2 / Amazon Linux
        ↓
Java 17
        ↓
SCP
        ↓
java -jar
        ↓
Java Process
        ↓
TCP 8080 LISTEN
        ↓
HTTP 200
        ↓
Intentional Failure
        ↓
Process / Port / HTTP Check
        ↓
Restart
        ↓
Recovery
```

Sprint 1を通して、

**Code → Build → Artifact → Server → Process → Port → HTTP → Network**

という、Webアプリケーションが動作するまでのつながりを実際に構築・観測した。

今後はこのSpring Bootアプリケーションを育てながら、Java / Linux / AWS / Git / DevOpsの知識を段階的につなげていく。