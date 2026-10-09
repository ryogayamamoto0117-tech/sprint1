# Sprint 5：DockerイメージをECS Fargateで運用する — 構築・検証・障害対応の詳細記録

**Project Nexus / 2026年10月 / AWSリージョン：東京（`ap-northeast-1`）**

本資料は、Sprint 5で実際に構築・設定・観測した内容を、後から設計や障害調査に再利用できる形で残した技術記録である。プロジェクト全体の紹介を目的とするREADMEとは異なり、構成値、作業の経緯、採用した理由、疎通試験、復旧試験、学習終了後の運用状態まで記載する。

過去のSprint 5引き継ぎ資料には、当時の**作業予定**も含まれている。本書では、**2026年10月9日までの新しい会話で確認できた結果を優先**し、古い予定を完了実績として扱わない。履歴間で一致しない値や、実行を確認していない操作は、そのまま事実と断定しない。

---

## 1. Sprint 5の目的と、今回到達した状態

Sprint 3では、Spring BootアプリケーションをJARとしてAmazon EC2に配置し、Javaランタイムを導入して`systemd`で起動・停止・再起動を管理していた。EC2を2台、別アベイラビリティゾーンに配置し、ALBから振り分ける構成も構築した。しかし、この方式ではOS・ランタイムの準備、JARの配布、systemdの設定や、サーバー単位での更新手順を継続して管理する必要があった。

Sprint 4ではDockerによるコンテナイメージの作成と、GitHub ActionsからAmazon ECRへイメージを登録する経験を積んだ。Sprint 5では、このDockerイメージを実際にAWS上で動かし、ECSサービスで継続運用するところまで学習した。

今回、`sprint5-app:1`を使ってSpring BootコンテナをAWS Fargate上で起動した。最初はStandalone Taskとして実行し、起動ログとネットワークを確認した。その後、ECSサービス`sprint5-app-service`を作成し、既存のALBからFargateへ転送する仕組みを設定した。`/health`への正常応答だけではなく、`/records`から既存RDS PostgreSQLの5件のレコードを取得できることまで検証した。

さらに、希望タスク数が1の状態で唯一の実行中タスクを意図的に停止し、ECSが代替タスクを作成して希望タスク数に復帰することを確認した。ログはCloudWatch Logsに蓄積され、起動・終了時の挙動を追跡できた。

学習終了時には、ECSサービスの希望タスク数を`1 → 0`に変更し、実行中・保留中・希望タスク数がすべて0であることを確認した。RDSには一時停止操作を実施し、最後に確認した時点では停止処理中だった。ALB、ECR、タスク定義などは、今後の学習に再利用する方針とした。

なお、当初の引き継ぎ資料には「Desired Count 2での複数AZ検証」「イメージA/Bによるローリングデプロイ・ロールバック」「Deployment Circuit Breakerの実験」も後続の予定として記録されていた。これらは**今回の会話記録だけでは実施済みと確認できない**ため、本書では完了した作業に含めない。ECSサービスのデプロイ方式としてローリング更新を選択したことと、実際にバージョンを切り替えるローリングデプロイを試験したことは区別する。

---

## 2. 今回構築したシステム全体像

```text
Windows PC（PowerShell / curl.exe）
           |
           | HTTP :80
           v
+------------------------------------------+
| 既存のApplication Load Balancer           |
| sprint3-alb                              |
| HTTP:80 Listener                        |
+------------------------------------------+
       |                              |
       | X-Environment: sprint5       | その他（Default）
       v                              v
+------------------------+    +----------------------+
| sprint5-fargate-tg     |    | sprint3-tg           |
| Target type: ip        |    | Target type: instance|
| HTTP :8080             |    | EC2 / Sprint 3       |
| Health check: /health  |    +----------------------+
+------------------------+
       |
       v
+------------------------------------------+
| ECS Cluster: sprint5-ecs-cluster         |
| ECS Service: sprint5-app-service         |
| Desired Count: 1（実験時）→ 0（終了時）    |
| Fargate Task: sprint5-app:1             |
| Container: sprint5-app / TCP :8080       |
+------------------------------------------+
       |
       | PostgreSQL TCP :5432
       v
+------------------------------------------+
| 既存RDS: sprint2-postgres               |
| PostgreSQL / sprint2db                  |
+------------------------------------------+

Spring Boot stdout / stderr
       |
       v
awslogs → CloudWatch Logs /ecs/sprint5-app

Spring Boot JAR → Dockerイメージ → ECR（sprint4-app）
                                       |
                                       v
                              ECSタスク定義から参照
```

ALBとRDSは新規作成せず、Sprint 3／Sprint 2の環境を再利用した。これにより、新旧のアプリ実行基盤を同じVPCおよび同じデータベースに接続したまま比較できた。ALBのデフォルト転送先を変更せず、明示的なHTTPヘッダーを付けた場合だけFargateへ転送する設計にしたため、既存のSprint 3用ルートへの影響を抑えた。

### 2.1 主要リソース

| 分類 | 名前・設定 | 備考 |
|---|---|---|
| リージョン | `ap-northeast-1` | 東京 |
| VPC | `sprint1-v2-vpc` | `vpc-0f907ac22a8b7899a` |
| ECSクラスター | `sprint5-ecs-cluster` | Fargateタスクを管理 |
| タスク定義 | `sprint5-app:1` | タスク全体の実行条件を宣言 |
| ECSサービス | `sprint5-app-service` | タスク数維持・代替起動を管理 |
| コンテナ | `sprint5-app` | Spring Boot、TCP 8080 |
| イメージ保管 | ECR `sprint4-app` | Sprint 4の既存リポジトリ |
| ALB | `sprint3-alb` | 既存のInternet-facing ALB |
| 既存EC2向けTG | `sprint3-tg` | Target type `instance` |
| Fargate向けTG | `sprint5-fargate-tg` | Target type `ip` |
| FargateのSG | `sprint5-fargate-sg` | `sg-0fb57492aab6c891c` |
| RDS | `sprint2-postgres` | 既存PostgreSQL |
| RDSのSG | `sprint2-rds-sg` | `sg-0caee68876e3947cc`（引き継ぎ資料） |
| CloudWatch Logs | `/ecs/sprint5-app` | コンテナの標準出力・標準エラーを送信 |

**設定履歴に差がある項目：** ALB側セキュリティグループのIDは、今回の追加引き継ぎ資料では`sg-0d3ccb6fb13df2309`（`sprint3-alb-sg`）、前のMarkdown・別の進捗要約では`sg-053bcfd8c0592185b`と記録されている。**これらは同一のIDではないため、現在ALBにアタッチされたSGとFargate SGのインバウンドの送信元は、コンソールまたはAWS CLIで照合する必要がある。** 本書では、両者を黙って同一視しない。通信試験が成功したことは確認済みだが、それだけではどちらが設定されているかを確定できない。

---

## 3. DockerイメージとAmazon ECR

### 3.1 Dockerを使う理由

Dockerfileは、アプリケーションの実行環境を組み立てる手順をコードとして記述するためのファイルである。Dockerイメージはその手順から作られる配布物であり、コンテナはイメージから起動した実行単位である。ローカルWindowsにインストールしたソフトウェアを無条件に丸ごとコピーする仕組みではない。

Sprint 3ではEC2ごとにJavaランタイム、JAR配置、systemdの設定を意識した。今回のコンテナ化によって、Spring Bootを実行するためのランタイムとアプリケーションをイメージにまとめ、同じイメージを異なる実行環境へ配布できるようにした。ただし、コンテナイメージに含まれないVPC・環境変数・Secrets・DB・CPUアーキテクチャまで自動的に共通化されるわけではない。

### 3.2 今回使ったDockerベースイメージ

追加引き継ぎ資料によると、Dockerベースイメージは以下のとおり。

```dockerfile
FROM eclipse-temurin:17-jre
```

Java 17のJREを備えたベースイメージを利用している。実際のDockerfileの`COPY`・`EXPOSE`・`ENTRYPOINT`等の全文、Dockerビルドの実行コマンドとそのログについては、ソースファイルをこの時点で照合していないため再現コマンドとして断定しない。

### 3.3 ECRリポジトリとイメージの履歴

Sprint 4から利用しているECRリポジトリは`sprint4-app`である。引き継ぎ資料に記録されたURIは以下のとおり。

```text
237575223564.dkr.ecr.ap-northeast-1.amazonaws.com/sprint4-app
```

過去の記録で確認されたイメージは少なくとも次の2つ。

| 区分 | イメージタグ | Digest | ルートの応答 |
|---|---|---|---|
| A（旧） | `0401d19b60e8508edb21c622f0eac8f6ddceeffb` | `sha256:0a5a19fddeae485526e42a45a94f0cf208bfc81f912ab250060e5c8e169d40f3` | `Hello Sprint 3 CI/CD!` |
| B（新） | `7cb0cad8ede49e6b2b95aeb0976252b7708dc49d` | `sha256:7ec9a570a2d3fcf3196616252c8298dd654f635222b1b51170edec59a64badf2` | `Hello Sprint 4 Docker v2!` |

タグはイメージを参照するためのラベルであり、Digestはコンテンツを識別する値である。両者を同じものとして扱わない。

ECSでイメージを指定する場合は通常`<リポジトリURI>:<タグ>`等を用いる。**`sprint5-app:1`が最終的にAとBのどちらを参照していたかは、追加資料でも未確定**であり、両方がECRに存在することをもってBが稼働したとは断定できない。後から再現する場合は、タスク定義の実際の`image`値またはJSONを参照する。

### 3.4 GitHub Actionsとの関係

Dockerイメージのビルド・ECRへのpushは、Sprint 4でGitHub Actionsを用いて経験している。Sprint 4の作業ブランチは`sprint4-docker`、PRは`#1`で、マージ済みと記録されている。

関連するファイルは`.github/workflows/ci.yml`と`.github/workflows/container-build.yml`。以前、旧Sprint 3向けのCI/CDが後続Sprintのpushでも意図せず起動する問題があり、`ci.yml`のトリガーを`workflow_dispatch`に変更する対応を行った。ただし、その修正が現在のGitHub上でどのコミットに確定しているかは再照合が必要である。

また、`container-build.yml`には、READMEや`docs/**`のみを更新した場合にDockerビルド／ECR pushを走らせないようにする`paths-ignore`の追加を検討していた。**Sprint 5のドキュメントpush前に、現在のワークフロートリガーを確認することが重要**である。実際に反映済みかは、この資料では断定しない。

---

## 4. ECSタスク定義：`sprint5-app:1`

### 4.1 タスク全体のCPU・メモリとコンテナ定義

| 項目 | 設定 |
|---|---|
| ファミリー／リビジョン | `sprint5-app:1` |
| 当時の登録状態 | ACTIVE |
| 起動タイプ | Fargate |
| OS / CPUアーキテクチャ | Linux / X86_64 |
| ネットワークモード | `awsvpc` |
| タスクCPU | `0.25 vCPU`＝256 CPU units |
| タスクメモリ | `0.5 GB`＝512 MiB |
| コンテナ数 | 1 |
| コンテナ名 | `sprint5-app` |
| Essential | Yes |
| コンテナポート | TCP 8080 |
| コンテナ個別CPU設定 | 未設定 |
| コンテナ個別メモリ制限 | 追加設定なし |
| コンテナヘルスチェック | P2時点で未設定 |

256 CPU unitsと512 MiBは、**タスク全体に割り当てた値**である。単一コンテナだからといって、コンテナ定義の個別CPU・メモリ制限に同じ値を明示していたわけではない。CPUやメモリの調整は、通常タスク定義の新リビジョンを作成してサービスへ適用する。一方、希望タスク数（Desired Count）はECSサービス側の設定であり、タスクのスペックとは別である。

Essentialコンテナが停止すると、そのタスクは維持できない。Standalone Taskの場合は自動的に新しいタスクが補充されるわけではないが、ECSサービスでDesired Countを指定している場合には、サービスが代替タスクを起動しようとする。**Essentialの設定自体が自己復旧を担うのではなく、自己復旧はECSサービスの管理機能による。**

今回はこの小さなリソース構成でSpring Bootの起動に成功した。ただし、高負荷時のCPU不足、メモリ不足、OOM停止の有無や適正サイズについては負荷試験を行っていない。Fargateエフェメラルストレージにも明示的な追加変更は行っていない。

### 4.2 コンテナヘルスチェックとALBヘルスチェックの違い

P2のタスク定義では、**ECSコンテナヘルスチェックを設定していない**。そのため、タスク詳細でコンテナのHealth Statusが`UNKNOWN`と表示された。これは、その表示だけでSpring Bootが故障していることを意味しない。

後続のP3では、別機能である**ALBターゲットグループのHTTPヘルスチェック**を`/health`に設定した。この2種類のヘルスチェックを混同しない。

また、タスク状態`RUNNING`はコンテナ起動の状態であり、Spring BootがすべてのAPIを正常に処理できることを直接保証するものではない。今回はログ、ALBのHealthy判定、`/health`、`/records`を別々に確認している。

### 4.3 Spring Bootの環境変数

RDS接続に必要な情報はECSタスク定義からコンテナへ渡す構成にした。

| 環境変数 | 設定値 |
|---|---|
| `DB_HOST` | `sprint2-postgres.c7y2kowyu6ih.ap-northeast-1.rds.amazonaws.com` |
| `DB_PORT` | `5432` |
| `DB_NAME` | `sprint2db` |
| `DB_USER` | `postgres` |

DBパスワードだけは平文の環境変数として直接記述せず、AWS Systems Manager Parameter Storeの**SecureString**を参照した。

```text
Container Secret Name : DB_PASSWORD
ValueFrom             : /sprint3/db/password
```

ここには**パスワードの値は一切記載しない**。タスク定義のSecretsから参照させることで、DockerfileやGitHubのソースコードにDBパスワードを直接含めずに済む。

### 4.4 IAMロール

今回のTask Execution Roleは`sprint5-ecs-task-execution-role`で、AWS管理ポリシー`AmazonECSTaskExecutionRolePolicy`をアタッチした。さらに、特定のParameter Storeパラメータを参照するために、`ssm:GetParameters`を許可するインラインポリシーを追加した。

```text
Role   : sprint5-ecs-task-execution-role
Policy : AmazonECSTaskExecutionRolePolicy
Action : ssm:GetParameters
Resource:
arn:aws:ssm:ap-northeast-1:237575223564:parameter/sprint3/db/password
```

Execution Roleは、ECSがイメージをECRから取得し、ログをCloudWatch Logsへ送信し、コンテナ起動時にParameter Storeのシークレットを取り出すために用いる。一方、**Task Roleは今回未設定**である。Spring Bootアプリケーション自身がS3やBedrock等のAWS APIを直接利用する設計にはしていないためである。

この違いは重要である。Execution RoleとTask Roleを混同して、アプリケーションがAWS APIを呼ぶための権限をExecution Roleに付与するのは適切ではない。SecureStringの暗号化方式によってはKMS関連の追加権限が必要になる場合があるが、今回のキーの種類は未確認。

---

## 5. Standalone Taskによる先行動作確認（P2）

ECSサービスを作成する前に、Standalone TaskとしてFargateの動作を確認した。Standalone Taskは一度起動したタスクを単体で実行する方法であり、ECSサービスのDesired Countによる自動補充機能を持たない。

### 5.1 Spring Bootの起動ログ

過去のログから、以下を確認した。

| 項目 | 観測値 |
|---|---|
| Java | `17.0.20.1` |
| Spring Boot | `4.1.1` |
| Tomcat | HTTP 8080で起動 |
| Spring Boot起動時間 | 約29.394秒 |
| 起動完了ログ | `Started Sprint1Application in 29.394 seconds` |
| 当時のスクリーンショット | 表示範囲ではERROR／Exceptionなし |

この結果から、ECRに保存したイメージをFargate上で取得・実行でき、Spring Bootの起動が完了したことが分かる。ただし、**起動ログだけではRDS接続成功は証明できない**ため、後からECSサービスを作成して`/records`の実通信試験を行った。

### 5.2 Standalone Taskで観測したネットワーク情報

P2で起動した**その時点の特定タスク**に割り当てられた値は以下のとおり。

| 項目 | 観測値 |
|---|---|
| ネットワークモード | `awsvpc` |
| サブネット | `sprint3-public-subnet-c` |
| AZ | `ap-northeast-1c` |
| プライベートIP | `10.1.4.210` |
| パブリックIP | `13.115.124.9` |
| ENI | `eni-0cc857cf96b539e82` |
| セキュリティグループ | `sprint5-fargate-sg` |

これは過去のタスクの**実測値**であり、現在や再起動後のタスクに同じIP／ENIが付与されるわけではない。Fargateのタスクが置き換わるとIPアドレスも変わり得るため、ALBターゲットを固定IPで運用せず、ECSサービスから自動登録する設計とした。

先行検証のStandalone Taskは、学習終了時に停止し、P3へ進む前に実行中タスクが0であることを確認している。

---

## 6. VPC、サブネット、ルーティング、通信制御

### 6.1 配置先と採用理由

既存VPC`sprint1-v2-vpc`（`vpc-0f907ac22a8b7899a`）に、次のパブリックサブネットを利用した。

| AZ側 | サブネット名 | サブネットID |
|---|---|---|
| Public A | `sprint1-v2-public-subnet` | `subnet-055fdea94553f1c05` |
| Public C | `sprint3-public-subnet-c` | `subnet-0ff9c36a6659e052d` |

両サブネットが使用するルートテーブル`sprint1-v2-public-rt`には、引き継ぎ記録上、次の経路が存在した。

```text
10.1.0.0/16  → local
0.0.0.0/0    → igw-0cc3b2072ff38bd57
```

FargateタスクにはパブリックIPv4の自動割り当てを有効にした。主な理由は、**NAT Gatewayを新規作成せず**、ECRなどのAWS公開エンドポイントへ通信する学習環境を構成するためである。

`local`は同一VPC内のRDS等へ到達するための経路、IGWへのデフォルトルートはインターネット方向の経路を意味する。ただし、ルートがあるだけでは通信が認められるわけではなく、セキュリティグループの通信制御やIAM権限も必要である。

この構成は学習向けのコストと操作容易性を優先したもの。実務の構成では、プライベートサブネット、NAT GatewayまたはVPCエンドポイントを利用する方法も検討対象となる。今回はNAT Gatewayや追加のVPCエンドポイントを新規作成していない。

### 6.2 ECSサービスのVPC・SG入力で修正した内容

サービス作成時のネットワーク設定画面には、当初意図していないVPC`vpc-066c36eb153332c44`と`default`セキュリティグループが表示されていた。これを、既存のSprint 5構成に合わせて、VPC`vpc-0f907ac22a8b7899a`と`sprint5-fargate-sg`へ変更した。

これは**入力画面の設定の不一致に気づいて修正した記録**であり、誤設定のままデプロイして障害が発生したことを意味しない。コンソールの初期選択値をそのまま採用せず、依存リソースを照合する重要性を学んだ。

### 6.3 ALB → Fargate → RDSの通信とSG

```text
Windowsクライアント
     |
     | HTTP :80
     v
ALB（ALB側SGでHTTP 80を許可）
     |
     | TCP :8080
     v
Fargate（Fargate側SGでALB SGからの8080を許可）
     |
     | TCP :5432
     v
RDS（RDS側SGでFargate SGからの5432を許可）
```

Fargateのセキュリティグループは`sprint5-fargate-sg`（`sg-0fb57492aab6c891c`）。P2時点ではインバウンドルールが0件だったが、P3で**ALB側のSGを送信元とするカスタムTCP 8080**のルールを追加した。ALB SGの実際のIDは上述のとおり記録に相違があるため再照合が必要である。

追加資料には、設定した説明が`Allow HTTP 8080 from Sprint3 ALB`であることも記録されている。ALBのSGにはHTTP 80の受信許可があり、送信元CIDRの詳細は記録上未確認。ALB SGのアウトバウンドでは`0.0.0.0/0`宛ての全トラフィック許可が確認されている。

RDS用SG`sprint2-rds-sg`（`sg-0caee68876e3947cc`）では、既存のインバウンドルール2件を維持し、Sprint 5用に次のルールを追加した。

```text
Type        : PostgreSQL
Protocol    : TCP
Port        : 5432
Source      : sg-0fb57492aab6c891c
Description : Allow PostgreSQL access from Sprint 5 ECS Fargate tasks
```

Spring BootがRDSへ通信を**開始する側**であるため、Fargate SGのアウトバウンドとRDS SGのインバウンドを適切に設定すればよい。RDSから戻る応答のためだけにFargate SGへTCP 5432のインバウンドルールを追加する必要はない。セキュリティグループはステートフルなので、許可された通信に対する応答パケットは戻れる。

IPアドレスを直接固定するのではなくSG同士を参照することで、Fargateタスクの入れ替えに伴うIP変化を吸収できる。パブリックIPが付いていても、8080番ポートへのインバウンドをALB SGに限定すれば、そのポートを任意のインターネット送信元へ公開する構成とは異なる。

---

## 7. ALBを使ったEC2とFargateの振り分け（P3）

### 7.1 既存のALBを維持する設計

Sprint 3で使用していた`sprint3-alb`のHTTP:80リスナーを再利用した。既存の`sprint3-tg`はEC2用の`instance`ターゲットグループであり、HTTP 8080へ転送する。

Fargate向けには新しく`sprint5-fargate-tg`を作成し、ターゲットタイプを`ip`とした。ECSタスクの`awsvpc`ネットワークモードでは、各タスクがENIとIPを持つためである。ターゲットを手動でIP登録する運用にはせず、ECSサービスとターゲットグループの関連付けによって自動登録させた。

### 7.2 Fargateターゲットグループの設定

| 項目 | 設定 |
|---|---|
| 名称 | `sprint5-fargate-tg` |
| ターゲットタイプ | `ip` |
| IPアドレスタイプ | IPv4 |
| プロトコル | HTTP |
| ポート | 8080 |
| VPC | `vpc-0f907ac22a8b7899a` |
| プロトコルバージョン | HTTP1 |
| ヘルスチェック | HTTP |
| ヘルスチェックパス | `/health` |
| ヘルスチェックポート | `traffic-port` |
| 成功コード | 200 |
| チェック間隔 | 30秒 |
| タイムアウト | 5秒 |
| 正常しきい値 | 5 |
| 異常しきい値 | 2 |
| Target Optimizer | オフ |
| ターゲットの手動登録 | なし |

後続の画面では**Healthy 1、Unhealthy 0**を確認した。なお、Healthyのしきい値が5でも、新規登録ターゲットは初回の正常チェックでHealthyと判定される場合があり、「復旧には必ず30秒×5回かかる」とは言えない。

### 7.3 HTTPヘッダーを使ったリスナールール

既存環境を壊さないよう、デフォルト転送先は`sprint3-tg`のまま維持した。その上に優先度1のルールを追加した。

```text
Listener : HTTP :80
Priority : 1
Condition:
  Header Name  = X-Environment
  Header Value = sprint5
Action:
  Forward to sprint5-fargate-tg

Default:
  Forward to sprint3-tg
```

`X-Environment: sprint5`を指定したリクエストはFargate、それ以外は従来のEC2へ転送する。**このヘッダーはテスト用のルーティング条件であり、認証やアクセス制御の代わりにはならない。**

### 7.4 ECSサービスを作成した際の設定

| 項目 | 設定 |
|---|---|
| クラスター | `sprint5-ecs-cluster` |
| サービス | `sprint5-app-service` |
| タスク定義 | `sprint5-app:1` |
| 起動タイプ | Fargate |
| デプロイ方式 | ECS Rolling Update |
| 実験時の希望タスク数 | 1 |
| VPC | `sprint1-v2-vpc` |
| サブネット | Public A / Public C |
| セキュリティグループ | `sprint5-fargate-sg` |
| パブリックIP | オン |
| ロードバランサー | `sprint3-alb` |
| ターゲットグループ | `sprint5-fargate-tg` |
| コンテナ／ポート | `sprint5-app` / 8080 |
| ECSヘルスチェック猶予期間 | 60秒 |

60秒の猶予期間は、ALBのヘルスチェック間隔30秒とは別である。これはタスク起動直後にヘルスチェック失敗が原因でECSが早期にタスクを置き換えることを猶予する設定であり、Spring Bootの起動を60秒遅らせるものではない。

サービスがACTIVEとなり、タスクがRUNNINGになって、ALBのターゲットもHealthyになることを確認した。

---

## 8. 実際に行った疎通検証

### 8.1 ALB → Fargate → RDSのAPI確認

Windows PowerShellから、Fargate側へ振り分けるHTTPヘッダーを付けて`/records`を呼び出した。

```powershell
curl.exe -i -H "X-Environment: sprint5" http://sprint3-alb-632878014.ap-northeast-1.elb.amazonaws.com/records
```

HTTPステータスは`200 OK`。応答としてPostgreSQL内の**5件のJSONレコード**が返った。

この結果は、少なくとも検証時点において次の経路がすべて成立したことを示す。

```text
クライアント → ALB:80 → Fargate:8080 → Spring Boot
                                         |
                                         v
                                   PostgreSQL:5432
                                         |
                                         v
                                     JSON応答
```

`/health`へのアクセスも成功し、`OK`を確認した。`/health`と`/records`は別の確認である。ALBがHealthyでもDBアクセスが失敗する可能性があるため、DBに依存するAPIを別途実行する必要がある。

### 8.2 Sprint 3の障害経験を踏まえた確認

Sprint 3では、EC2側のSGにALBからの8080番通信を許可していなかったため、ターゲットがUnhealthyになった。ALB SGからの8080を許可するとHealthyへ復帰した。

別の場面では、PostgreSQLの認証エラーによって`/records`がHTTP 500になり、`CannotGetJdbcConnectionException`や`PSQLException`がログに出ていたにもかかわらず、`/health`が成功したためALBはHealthyを維持した。

今回のSprint 5では、この経験を踏まえて、タスクRUNNING、Spring Boot起動ログ、ターゲットHealthy、`/health`、DB依存の`/records`を混同せずに確認した。追加の引き継ぎ資料にはDBのPOST/GETを確認対象とする計画も記載されているが、今回確実に確認できた実績は、少なくとも`/records`のGET相当のアクセスによるデータ取得である。

---

## 9. ECSサービスによる自己復旧試験

### 9.1 手順と観測

ECSサービスの希望タスク数を1にしたまま、唯一のRUNNINGタスクを意図的に手動停止した。サービスがタスクを補充するかを観察した。

```text
停止前：Desired = 1 / Running = 1 / Pending = 0
     ↓
実行中のFargateタスクを手動停止
     ↓
停止直後：Running = 0
     ↓
ECSサービスが代替タスクを作成（Pendingを確認）
     ↓
復旧後：Desired = 1 / Running = 1 / Pending = 0
     ↓
ALB経由の /health が HTTP 200
```

タスクを停止したにもかかわらず、ECSサービスが希望タスク数を維持するために**新しいタスクを起動**した。EC2上のsystemdのように同じホスト内の同じプロセスだけを再起動する方式ではなく、タスクそのものの置き換えを行う点が重要である。

起動から復旧までが速く感じられる挙動を観測したが、ストップウォッチ等による厳密な停止時間・復旧時間の測定値はない。**実測値がないため、復旧時間を秒単位で記述しない。**

### 9.2 自己復旧と無停止運用は別

希望タスク数が1である以上、唯一のタスクの停止中はアプリケーションを処理できない時間が発生し得る。したがって、今回確認できたのは**Desired Countを復元する自己復旧**であり、エンドユーザーから見た無停止を保証する高可用性ではない。

当初の計画にあるDesired Count 2による複数AZ配置確認、片系停止中の継続稼働、イメージA/Bのローリングデプロイ・ロールバック、Deployment Circuit Breakerなどは有用な次の検証テーマだが、現時点でそれらを実施済みと断定する根拠はない。

---

## 10. CloudWatch Logsによるログ収集と調査

### 10.1 ロググループを手動作成した経緯

今回のロググループは`/ecs/sprint5-app`。**タスク定義を作成した際に手動で先に作成した**。作成初期にはロググループが存在せず、`awslogs-create-group`を用いた自動作成では権限不足が生じる可能性を考慮したためである。

ロググループの手動作成後、タスク定義のログ設定から`awslogs-create-group=true`を削除した。以後、このタスク定義では作成済みロググループに出力する構成とした。

```text
Log Driver             : awslogs
awslogs-group          : /ecs/sprint5-app
awslogs-region         : ap-northeast-1
awslogs-stream-prefix  : ecs
awslogs-create-group   : true は設定しない
```

### 10.2 ログが保存される流れ

```text
Spring Boot
   ↓ 標準出力（stdout）・標準エラー（stderr）
Fargateのログドライバー awslogs
   ↓
CloudWatch Logsのロググループ /ecs/sprint5-app
   ↓
タスクごとに識別できるログストリーム
   ↓
ECSサービスの「ログ」タブ / CloudWatch Logsコンソール
```

ECSサービス画面のログタブからSpring Bootログを確認し、「CloudWatchで表示」を利用してCloudWatch Logs側の画面へ移動できた。ログを発行するのはSpring Boot側であり、CloudWatch Logsはログを**集約・保存・検索するサービス**である。

### 10.3 画面で確認した実際のログ

起動・終了のログとして、次のような記録を確認した。

```text
DispatcherServlet : Completed initialization in 89 ms
HikariPool-1 - Shutdown completed.
Graceful shutdown complete
```

`DispatcherServlet`のログはWeb処理の初期化、`HikariPool`はDB接続プールの終了、`Graceful shutdown complete`は終了時の正常な後処理に関係する。起動前後や終了前後のログが**異なるタスクID**から確認され、コンテナが入れ替わっても過去に送信済みのログを追えると分かった。

ただし、これらのログだけで、どのタスクがなぜ停止したかを確定することはできない。障害の原因を追う場合は、タスクID、ECSイベント、Stopped reason、ログの時刻などを対応付ける必要がある。

Sprint 3では`journalctl -u sprint1`を使って各EC2上のsystemd管理アプリのログを確認した。Sprint 5ではCloudWatch Logsに集約することで、ホストOSへ接続せずタスク単位のログを閲覧できた。CPUやメモリのグラフ表示はCloudWatch Metrics、アラームはCloudWatch Alarmsなど、ログとは別の機能である。

---

## 11. コストと学習終了時の後片付け

### 11.1 Fargateの料金構造と参考試算

ECSのFargate起動タイプでは、主にタスクの割り当てvCPU・メモリと利用時間に応じて料金が発生する。今回のタスクは`0.25 vCPU / 512 MiB`、タスク数1である。

当時の参考単価と為替`1 USD = 150円`を仮定した概算は次のとおり。

| 期間 | FargateのCPU・メモリ料金の参考値 |
|---|---:|
| 1時間 | 約2.3円 |
| 1日（24時間） | 約55円 |
| 30日（720時間） | 約1,660円 |

これは当時の概算であり、最新の料金や実際の請求額ではない。データ転送、パブリックIPv4、追加ストレージ、CloudWatch Logsなどは別途考慮する必要がある。

### 11.2 クレジット確認

2026年10月9日のAWS画面では、無料プランの残りクレジットが**`$128.21`**、残り日数が**114日**、画面上の期限が**2027年1月30日**と表示された。請求情報やCost Explorerの一部画面ではアクセスまたは表示上の問題があり、サービス別の実請求額は確認できていない。

クレジット残高があることと、個々のサービスで料金が発生していないことは同義ではない。対象サービスや有効期限も踏まえてリソースの稼働状態を管理する必要がある。

### 11.3 ECSサービスを削除せず停止

ECSサービス`sprint5-app-service`の「サービスを更新」から、**必要なタスク数（Desired Count）を1から0に変更**した。更新が完了した後、次の状態を確認した。

```text
Desired = 0
Running = 0
Pending = 0
```

希望タスク数が1のまま個別タスクを停止すると、ECSサービスが新しいタスクを起動してしまう。サービスを残しつつ実行料金を止めるため、**サービスのDesired Countを0にする必要がある**。これによりタスクの稼働料金を抑え、クラスター・サービス・タスク定義は再利用可能な状態で保持した。

### 11.4 RDS・ALB・ECRの扱い

RDS`sprint2-postgres`は、確認時点で「利用可能」だった。その後、一時停止操作を実行し、ユーザーが**「停止処理中」**と報告した。**停止完了画面は未確認**のため、本資料では停止済みと断定しない。

RDSはデータを保持して再利用できるが、停止中もストレージなどの料金が残る。また、通常のRDS DBインスタンスは一時停止後、最大7日程度で自動再起動するため、永続的な課金停止策ではない。

ALB`sprint3-alb`は稼働中であり、今後も使用するため残す方針とした。ALBにはEC2のような一時停止機能がないため、アクセスがなくても稼働時間・LCU等に基づく課金が継続し得る。

ECRのイメージも後続の学習で再利用するため残した。CloudWatch Logsのログ、タスク定義、ECSクラスター・サービスも維持する。ECRの実際の保存容量とCloudWatch Logsの保存期間・料金は未確認である。

### 11.5 再利用時の起動順序

次回`/records`などDB依存APIを確認する場合、RDSが停止していれば先に起動し、`Available`へ戻るのを確認する。その後、ECSサービスのDesired Countを`0 → 1`に更新し、タスクRUNNING、ALBターゲットHealthy、`/health`および`/records`の応答を順に確かめる。RDSの再起動所要時間は一定ではなく、DBが利用可能になる前にFargateだけ起動するとDB依存APIが失敗する可能性がある。

---

## 12. Sprint 3のEC2構成とSprint 5のFargate構成の違い

| 観点 | Sprint 3（EC2） | Sprint 5（ECS / Fargate） |
|---|---|---|
| アプリ配布 | JARファイルをEC2へ配置 | DockerイメージをECRから取得 |
| Java実行環境 | EC2上にインストール | Dockerイメージに含める |
| 管理対象 | EC2、OS、systemd、アプリプロセス | タスク定義、ECSサービス、アプリコンテナ |
| 実行基盤 | EC2 | AWS Fargate |
| スケールの単位 | EC2インスタンスやプロセス | ECSのタスク数 |
| LBターゲット | `instance` | `ip` |
| ログ | `journalctl -u sprint1` | `awslogs` → CloudWatch Logs |
| 復旧 | systemdによるプロセス再起動等 | Desired Countを維持する代替タスク起動 |
| DB | RDS PostgreSQL | 同じRDS PostgreSQL |

今回の重要な学びは、単にEC2の代わりにFargateを選んだことではない。**Dockerがアプリケーション実行環境をパッケージ化し、ECRが保存先となり、ECSが望ましいタスク数を管理し、Fargateがそのタスクを動かす**という役割分担を理解できたことにある。

さらに、ホストを直接管理する方法から、宣言した状態をクラウド側が維持する方法へ移行したことで、今後のオートスケーリング、IaC、CI/CD、SRE／Platform Engineeringにつながる設計・運用の考え方に触れられた。

---

## 13. 設計・運用を通じて得た考察

**アプリの生存とシステム全体の正常性は別。** ECSタスクがRUNNINGであっても、アプリの起動やDB接続が成功したとは限らない。ALBの`/health`が正常でも、`/records`はDB認証エラーなどで失敗し得る。何を正常とみなすかをサービスの特性に応じて設計する必要がある。

**自己復旧と高可用性は別。** Desired Count 1での代替タスク起動は自動復旧を示すが、停止時間をゼロにするわけではない。複数タスク、複数AZ、ALBによる正常なターゲットへの振り分け、DBの可用性などを合わせて設計する必要がある。

**タスクは入れ替わるものとして扱う。** タスクのIPやENIは固定しない。通信許可はIPリテラルではなくSG参照を利用し、永続化が必要なデータはRDSへ、ログはCloudWatch Logsへ送る。タスク内部の一時ファイルに永続的なデータを置く設計とは区別する。

**AWS上の実行権限は用途ごとに分ける。** ECSの起動準備に必要なExecution Roleと、アプリがAWS APIを呼ぶためのTask Roleを分ける。DBパスワードはParameter StoreのSecureStringから取得し、平文でGitHubに載せない。実際に必要な権限だけを付与することが重要になる。

**コストも非機能要件の一部である。** ECSサービスのタスクだけを止めても、ALBやRDSの課金は続く。ALBは再利用の利便性と継続課金のトレードオフを受け入れて維持し、FargateはDesired Countを0にすることで不要な稼働料金を抑えた。

**設定画面の初期値は正しい前提にしない。** ECSサービス作成時に別VPCやdefault SGが表示された例のように、既存システムとの依存関係を確認し、設定変更の理由を説明できる状態で進めることが重要である。

---

## 14. 次のIaC学習へ引き継ぐ内容

次の学習テーマはTerraformなどを用いたInfrastructure as Code（IaC）を想定する。今回作成したVPC、サブネット、SG、ALB、ターゲットグループ、リスナールール、ECSクラスター／タスク定義／サービス、IAM、ECR、CloudWatch Logs、RDSは、コードとして表現する対象を具体的に理解するための材料になる。

重要なのは、**既存リソースをIaC化するために、無条件で同名の新規リソースを作成しないこと**である。TerraformではStateと既存リソースの対応付け、Import、`terraform plan`による差分確認が必要になる。特に既存ALBやデータを含むRDSを意図せず置き換えないよう、依存関係とライフサイクルを理解して進めたい。

また、Dockerイメージのbuild／ECR push／ECSデプロイをCI/CDで接続する場合は、まず現在のGitHub Actionsのトリガー条件を確認する。ドキュメントだけの更新でコンテナビルドが不要に走らない設計や、旧ワークフローの意図しない起動を防ぐ設計も重要になる。

当初のSprint 5の計画にあった2タスク構成やA/Bイメージのデプロイ実験は、実施記録が確認できていないため、IaC学習と並行するか、別の検証テーマとして改めて扱う。負荷試験によるCPU・メモリの妥当性確認、ヘルスチェック設計、CloudWatchメトリクスとアラーム、プライベートサブネット化、HTTPS導入も将来的な改善候補である。

---

## 15. 作業記録としての留意事項

本資料にある**過去のIP・ENI・クレジット残高・ECSタスク数・RDS稼働状態**は、各確認時点の値であり、現在のAWSリソースを常に表すものではない。現状確認が必要になった際は、AWSコンソールやAWS CLIの結果を優先する。

また、次の点は過去資料だけでは結論が出ないため、今後の実ファイル・コンソール照合時に追加する。

- `sprint5-app:1`が実際に指定するECRイメージのタグ／Digest
- ALBにアタッチされたSG IDとFargate SGの8080番ルールの送信元SG ID（記録間の相違あり）
- 実際のDockerfile全文とビルドコマンドの履歴
- RDSの一時停止が完了したかどうか、およびその後の自動再起動の有無
- GitHub Actionsの現在の実行トリガー・対象ブランチ・修正コミット
- ECSのDesired Count 2、ローリングデプロイ／ロールバック、Circuit Breaker等の検証実績（現記録では未確認）

上記は作業を促すチェックリストではなく、**ドキュメントの根拠と確度を明示するための注記**である。未確認情報を実施済みの記録に置き換えないことを優先する。

---

## 16. まとめ

Sprint 5では、Sprint 4で作成したDockerイメージをECRから取得し、Spring BootアプリケーションをFargate上で起動できた。Standalone Taskの起動ログからJava 17、Spring Boot 4.1.1、Tomcatの8080番での稼働を確認した後、ECSサービスとして運用する構成を作った。

既存ALBのHTTPヘッダールールにより、従来のEC2構成を保持したままFargate構成へのリクエストを振り分けた。セキュリティグループによる通信制御と、Parameter Storeを使ったDB認証情報の受け渡しを組み合わせ、`/records`からRDS PostgreSQLの5件のレコードを取得できた。

ECSサービスの唯一のRUNNINGタスクを停止する実験では、代替タスクが作成され、希望タスク数1とALB経由の正常応答に復帰した。これにより自動復旧を実際に観測するとともに、1タスク構成では高可用性を保証できないことも理解した。

CloudWatch Logsでは、ロググループを手動作成した理由と`awslogs`の設定を確認し、タスクの起動・終了ログを調査した。学習終了時にはECSサービスの希望タスク数を0にして停止を確かめ、RDSを一時停止する操作を行い、ALBとECRは次のSprintに再利用することにした。

今回の成果は**コンテナを起動したことだけでなく、イメージ管理、IAM・Secrets、ネットワーク、DB接続、ログ、障害復旧、コストまでを含めて、AWS上のコンテナ運用を一通り経験したこと**である。次は、この構成をIaCによって表現し、変更差分と運用をコードで管理する段階へ進む。


