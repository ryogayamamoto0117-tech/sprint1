# Sprint 6 — TerraformによるAWSインフラのIaC化とECS/Fargateの再構築

> **Project Nexus / 実践記録**  
> 実施・検証日：2026年10月（最終疎通確認：2026-10-11）  
> 作業ブランチ：`sprint6-terraform`  
> 作業ディレクトリ：`infra/sprint6/`  
> リージョン：`ap-northeast-1`（東京）  
> **到達点：Terraformで構築・管理したECS/Fargate環境を既存ALB・RDSと接続し、`/health`と`/records`のHTTP 200を確認。検証後、FargateとRDSを停止。**

## 1. Sprintの目的と結論

### 1.1 目的

Sprint 1〜5では、EC2・RDS・ALB・Docker・ECR・ECS/Fargateを段階的に学習してきた。Sprint 6の中心テーマは、これらの知識を **Infrastructure as Code（IaC）** に結びつけること。

AWSマネジメントコンソールからリソースを一つずつ作成する方法に加え、Terraformで「望ましいAWS構成」をHCL（HashiCorp Configuration Language）として宣言し、差分の検証・作成・変更・運用を一連の手順として経験することを目標にした。

達成目標：

1. TerraformのProvider・HCL・State・`data`・`resource`・`plan`・`apply`を実際のAWS構築と結びつけて理解する。
2. Sprint 1〜5で作成したVPC・ALB・RDS・ECR等を必要に応じて再利用し、既存環境への影響を抑える。
3. Sprint 6専用のSG、IAM実行ロール、CloudWatch Logs、ECSタスク定義・クラスター・サービス、ALBターゲットグループ・リスナールールをTerraformで管理する。
4. FargateでSpring Bootアプリを起動し、ALB経由のHTTP応答とPostgreSQLへのDB接続を検証する。
5. 検証後に課金対象のタスク・DBを停止し、コード・検証結果をGitHubで再利用可能な記録として残す。

### 1.2 最終結果

| 検証対象 | 確認した結果 | 判定 |
|---|---|---|
| Terraformの構成チェック | `terraform validate`成功 | 成功 |
| Terraformによる構築・更新 | 各ステップの`plan`確認後に`apply` | 成功 |
| ECSタスク定義 | `sprint6-app` Revision 1 / `ACTIVE` | 成功 |
| ECSサービス | `Desired=1`, `Running=1`, `Pending=0` | 成功 |
| ALBターゲットヘルス | FargateタスクのIP `10.1.4.55:8080` が `healthy` | 成功 |
| HTTP `/health` | `HTTP/1.1 200` / 本文 `OK` | 成功 |
| HTTP `/records` | `HTTP/1.1 200` / PostgreSQL由来のJSONを5件取得 | 成功 |
| Fargateの後片付け | `Desired=0`, `Running=0`, `Pending=0` | 停止確認済み |
| RDSの後片付け | `sprint2-postgres`が`stopped` | 停止確認済み |
| GitHubへのPush | 本記録作成時点では未実施 | 残作業 |

> **結論：** ALBへのリクエストからFargateのSpring Bootアプリ、RDSのPostgreSQLまで、エンドツーエンドの疎通を確認できた。Terraformによる構築が意図したシステムの動作につながることを実証した。ただし、既存のVPC・ALB・RDS・ECRまでを含めた「完全なゼロからのTerraform再構築」ではない。

---

## 2. 構成の全体像

### 2.1 検証時のリクエスト経路

```text
開発PC / PowerShell
  |
  | curl.exe -H "X-Environment: sprint6" http://<ALB-DNS>/records
  v
既存ALB: sprint3-alb (HTTP:80)
  | 既存HTTPリスナー
  | リスナールール: Priority 2
  | 条件: X-Environment = sprint6
  v
Sprint 6用ターゲットグループ: sprint6-app-tg
  | target_type = ip / HTTP:8080
  | health_check = GET /health, HTTP 200
  v
Sprint 6用ECSサービス: sprint6-app-service
  | クラスター: sprint6-ecs-cluster
  | タスク定義: sprint6-app:1
  | 実行基盤: FARGATE / awsvpc
  | 2つのパブリックサブネット（異なるAZ）を指定
  v
Fargateタスク / Spring Boot / TCP:8080
  | アプリケーションのDB接続
  | TCP:5432（SGで許可）
  v
既存RDS: sprint2-postgres (PostgreSQL)
  |
  +--> JSONレスポンスが ALB 経由で開発PCに戻る
```

周辺構成：

- **ECR**：Sprint 4でビルドした既存イメージを取得する。
- **IAM実行ロール**：ECRイメージ取得、CloudWatch Logsへのログ送信、SSM Parameter StoreからのDBパスワード取得に必要な権限を付与する。
- **CloudWatch Logs**：コンテナログの保存先として`/ecs/sprint6-app`を使用する。
- **セキュリティグループ**：ALB→Fargateの8080番、Fargate→RDSの5432番を制御する。
- **Terraform State**：Terraformの管理対象と実際のAWSリソースを対応付ける。今回はローカルStateで運用した。

### 2.2 新規作成・既存再利用の切り分け

| リソース | Sprint 6での扱い | Terraformの表現 |
|---|---|---|
| 既存VPC | 再利用 | `data "aws_vpc"` |
| 既存ALB用SG・RDS用SG | 情報を取得して再利用 | `data "aws_security_group"` |
| 既存パブリックサブネット2つ | 再利用 | `data "aws_subnet"` |
| 既存ALBのHTTPリスナー | 再利用 | `data "aws_lb_listener"` |
| 既存ALB本体 | 再利用（作り直さない） | リスナーの`data`参照を経由 |
| 既存RDS / ECRイメージ / SSMパラメータ | 再利用 | エンドポイント・イメージURI・パラメータ名等で参照 |
| Sprint 6用CloudWatchロググループ | 新規作成 | `resource "aws_cloudwatch_log_group"` |
| Sprint 6用Fargate SGと通信ルール | 新規作成 | `resource "aws_security_group"`ほか |
| **既存RDS SGへのSprint 6用許可ルール** | 既存SG自体は再利用し、ルールのみ新規追加 | `resource "aws_vpc_security_group_ingress_rule"` |
| ECSタスク実行IAMロールとポリシー | 新規作成 | `resource "aws_iam_role"`ほか |
| ECSタスク定義・クラスター・サービス | 新規作成 | `resource "aws_ecs_*"` |
| Sprint 6用ALBターゲットグループ | 新規作成 | `resource "aws_lb_target_group"` |
| 既存ALBリスナー上の追加ルール | 新規作成 | `resource "aws_lb_listener_rule"` |

**重要：** `data`自体は参照用であり、既存AWSリソースをTerraformの管理下に取り込む操作ではない。一方、`resource`で定義した「既存RDS SGに追加するルール」は、既存のSGに対して実際に変更を加える。この区別は破壊的変更の防止に不可欠。

---

## 3. Terraformの導入・初期設定

### 3.1 実行環境

- Windows 11 / PowerShell / VS Code
- Gitブランチ：`sprint6-terraform`
- Terraformは`infra/sprint6/`ディレクトリで実行
- AWSリージョン：東京 `ap-northeast-1`
- AWS操作権限：設定済みのIAM認証環境を利用。セッション切れ時は`aws login`で再ログインする運用

関連するファイル：

```text
infra/
└── sprint6/
    ├── .terraform.lock.hcl
    ├── versions.tf
    ├── providers.tf
    ├── main.tf
    ├── data.tf
    ├── security-group.tf
    ├── iam.tf
    ├── ecs.tf
    └── alb.tf

docs/
└── sprint-6.md  （このファイル）
```

### 3.2 TerraformバージョンとProvider

`versions.tf`にTerraform本体とAWS Providerの条件を記述した。作業時に初期化されたAWS Providerのバージョンは`6.68.0`。

```hcl
terraform {
  required_version = ">= 1.16, < 2.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}
```

`providers.tf`ではAWSリージョンを設定した。

```hcl
provider "aws" {
  region = "ap-northeast-1"
}
```

基本操作：

```powershell
terraform init
terraform fmt
terraform validate
terraform plan
terraform apply
```

- `init`：Providerなどを用意し、作業ディレクトリを初期化する。
- `fmt`：HCLのインデント・書式を揃える。
- `validate`：設定の構文やProviderスキーマ、参照関係などを検証する。ただしAWS上の実行可能性やアプリの正常動作をすべて保証するわけではない。
- `plan`：AWSの現在の情報を踏まえ、追加・変更・削除の計画を示す。
- `apply`：計画に沿ってAWS API経由で変更を実行し、管理状態をStateへ反映する。

`terraform init`時に生成された`.terraform.lock.hcl`は、選択されたProviderのバージョンとチェックサムを記録するためGitで管理する。

---

## 4. Terraformの仕組みを理解するための基礎演習

本格的なECS構築前に、比較的小規模なCloudWatch Logsのリソースを使い、Terraformのライフサイクルを確認した。

### 4.1 CloudWatchロググループの作成

`main.tf`：

```hcl
resource "aws_cloudwatch_log_group" "sprint6" {
  name              = "/ecs/sprint6-app"
  retention_in_days = 14
}
```

実施した操作：

1. ロググループの新規作成を`plan`で確認し、`apply`する。
2. `aws logs`等のAWS CLIで実際のリソースを検証する。
3. `terraform plan`を再実行し、HCLと実環境が一致すると変更不要になることを確認する。
4. 保持期間を7日から14日に変更して、**新規作成ではなく既存リソースの更新**を経験する。
5. AWS CLI側で保持期間を30日に変えて意図的にドリフトを発生させ、Terraformで14日に戻す動作を確認する。
6. CloudWatchロググループのみを管理していた学習段階で、削除と再作成も試す。
7. `terraform state list`、`terraform state show`で管理対象と属性を調べる。

### 4.2 State・HCL・AWS実環境の違い

```text
HCL（.tfファイル）
  望ましい構成：/ecs/sprint6-app、保持期間14日

Terraform State
  管理中のリソースとAWS上の実体を対応付ける情報

AWS実環境
  APIで取得される実際の現在の設定値
```

- Stateは「AWSの現在の状態そのもの」ではない。Terraformがどの実リソースを管理しているかを把握するために使う。
- `Refreshing state...`は、管理中の`resource`についてAWS Providerが現在のAWS情報を取得する処理。
- `Reading...`は、`data`で指定した既存リソースの情報をAWSから取得する処理。
- AWSコンソールやCLIから管理対象を変更すると、HCLとの**ドリフト**が発生する可能性がある。
- `terraform plan`は変更内容を確認するための重要なレビュー工程。

### 4.3 Planの読み方

| 表示 | 意味 | 今回の実例 |
|---|---|---|
| `+ create` | 新規作成 | ロググループ、SG、IAM、ECSタスク定義・クラスター・サービス、TG、リスナールール |
| `~ update in-place` | 同じリソースを維持したまま設定変更 | ログ保持期間変更、既存ECSサービスへのALB関連付け、`desired_count`変更 |
| `-/+` | 削除後に再作成 | **今回のECSサービス接続作業では発生させていない** |
| `(known after apply)` | AWSへの反映後に決まる属性 | リソースARNやID、Revisionなど |
| `0 to destroy` | 削除対象がない | 既存リソースへの影響を抑えた各Planで確認 |

**学び：** `plan`をレビューせずに機械的に`apply`しない。特に`destroy`や`replace`の表示がないか確認する。

---

## 5. 既存AWSネットワークの再利用（`data.tf`）

### 5.1 データソースの定義

Sprint 6では、Sprint 1〜5で作成したネットワークを新規作成し直さず、`data`で参照した。

```hcl
data "aws_vpc" "existing" {
  id = "vpc-0f907ac22a8b7899a"
}

data "aws_security_group" "alb" {
  id = "sg-0d3ccb6fb13df2309"
}

data "aws_security_group" "rds" {
  id = "sg-0caee68876e3947cc"
}

data "aws_subnet" "public_a" {
  id = "subnet-055fdea94553f1c05"
}

data "aws_subnet" "public_c" {
  id = "subnet-0ff9c36a6659e052d"
}

data "aws_lb_listener" "existing" {
  arn = "arn:aws:elasticloadbalancing:ap-northeast-1:237575223564:listener/app/sprint3-alb/c2325d1f6dd1d305/154e5512925da50d"
}
```

| データソース | 対象 | 利用目的 |
|---|---|---|
| `aws_vpc.existing` | Sprint 1系の既存VPC | Sprint 6用SG・TGの所属先 |
| `aws_security_group.alb` | 既存ALB SG | ALBからFargateへの許可元 |
| `aws_security_group.rds` | 既存RDS SG | FargateからPostgreSQLへの許可ルール追加先 |
| `aws_subnet.public_a` | 東京1aの既存サブネット | Fargate配置先 |
| `aws_subnet.public_c` | 東京1cの既存サブネット | Fargate配置先 |
| `aws_lb_listener.existing` | Sprint 3 ALBのHTTP:80リスナー | 新たな振り分けルールの追加先 |

### 5.2 `data`と`resource`の区別

```hcl
# 既存VPCの情報を参照
data "aws_vpc" "existing" {
  id = "vpc-0f907ac22a8b7899a"
}

# Terraformに新規作成・管理させるSG
resource "aws_security_group" "fargate" {
  name   = "sprint6-fargate-sg"
  vpc_id = data.aws_vpc.existing.id
}
```

- `data`：AWSから既存リソースの情報を取得する。
- `resource`：Terraformが作成・変更・削除を管理するリソースを宣言する。
- `aws_vpc.existing.id`のように属性を参照することで、IDを必要な設定へ渡せる。

---

## 6. Fargateのセキュリティグループ構築（`security-group.tf`）

### 6.1 方針

既存のSprint 3/Sprint 5の通信経路をできるだけ維持し、Sprint 6専用のSGを追加した。

- 新規SG：`sprint6-fargate-sg`
- 実際に確認したSG ID：`sg-0a8ab759ef6a61b29`
- **ALB → Fargate**：TCP 8080 を、送信元が既存ALBのSGの場合に許可。
- **Fargate → RDS**：RDS側SGのインバウンドに、Sprint 6 Fargate SGを送信元としたTCP 5432を追加。
- **Fargateアウトバウンド**：今回は全プロトコル／IPv4全宛先を許可。学習用設定であり、本番向けの最小権限化は今後の課題。

### 6.2 Terraformで使ったリソースと参照関係

| Terraformリソース | 用途 |
|---|---|
| `aws_security_group.fargate` | Sprint 6用SG作成 |
| `aws_vpc_security_group_ingress_rule.alb_to_fargate` | ALB SGからSprint 6 SGへTCP 8080を許可 |
| `aws_vpc_security_group_egress_rule.fargate_outbound` | Fargateから外向きの通信を許可 |
| `aws_vpc_security_group_ingress_rule.fargate_to_rds` | 既存RDS SGへTCP 5432の許可ルールを追加 |

**学び：** 通信経路ごとに「どちらが接続を開始するか」「接続先は何番ポートか」「どのSGが送信元か」を明確にする。SGで許可しても、サブネットのルートやNACL、アプリ側の待受状態が適切でなければ通信は成功しない。

今回はCLIで既存のRDS SGルールが維持され、Sprint 6用の5432許可ルールが追加されたことを確認した。

> 既存RDSのSG自体を`resource`としてTerraformに取り込んだわけではない。あくまでそのSGに**新しいルールをTerraform管理で追加**した。

---

## 7. ECSタスク実行IAMロールの構築（`iam.tf`）

### 7.1 実行ロール

作成したIAMロール：`sprint6-ecs-task-execution-role`

構成した主な要素：

1. **信頼ポリシー（Trust Policy）**：`ecs-tasks.amazonaws.com`による`sts:AssumeRole`を許可。
2. **AWS管理ポリシーのアタッチ**：`AmazonECSTaskExecutionRolePolicy`を付与。
3. **SSM読み取りのインラインポリシー**：`ssm:GetParameters`を、`/sprint3/db/password`に相当するパラメータARNへ限定して許可。

利用するSSM Parameter Storeの名前：

```text
/sprint3/db/password
```

### 7.2 IAMロールで学んだこと

- **信頼ポリシー**：「誰／どのサービスがそのロールを引き受けられるか」。
- **権限ポリシー**：「引き受けた主体が何を実行できるか」。
- **IAMロールARNの参照**：ECSタスク定義側で`aws_iam_role.ecs_task_execution.arn`を指定する。
- **パスワードの管理**：DBパスワードの値そのものをHCLに書かず、SSMパラメータ名を指定する。

AWS CLIの`get-role`、`list-attached-role-policies`、`get-role-policy`でロール・アタッチ・インラインポリシーを確認した。

> 今回設定したのは**タスク実行ロール**。アプリケーションが実行中にAWS APIを呼ぶための「タスクロール」とは役割が異なる。今回はアプリケーションのAWS API利用を目的とした追加タスクロールは設定していない。

---

## 8. ECSタスク定義のIaC化（`ecs.tf`）

### 8.1 定義した内容

タスク定義ファミリー：`sprint6-app`  
登録を確認したRevision：`1`  
状態：`ACTIVE`

| 設定 | 値 | 意味 |
|---|---|---|
| `requires_compatibilities` | `FARGATE` | Fargateで実行 |
| `network_mode` | `awsvpc` | タスク専用ENIを利用 |
| `cpu` | `256` | 0.25 vCPU相当 |
| `memory` | `512` | 512 MiB |
| `execution_role_arn` | Sprint 6用IAM実行ロール | ECR、ログ、シークレット取得に使用 |
| コンテナ名 | `sprint6-app` | ECSで参照するコンテナ識別名 |
| イメージ | 既存ECRの`sprint4-app`イメージ | Sprint 4/5の成果を再利用 |
| `containerPort` | `8080` | Spring Bootの待受ポート |
| `DB_HOST` | `sprint2-postgres`のRDSエンドポイント | DB接続先 |
| `DB_PORT` | `5432` | PostgreSQLのポート |
| `DB_NAME` | `sprint2db` | DB名 |
| `DB_USER` | `postgres` | DBユーザー名 |
| `DB_PASSWORD` | SSM `/sprint3/db/password` | 秘密値を実行時に渡す |
| ログ | `awslogs`、`/ecs/sprint6-app` | CloudWatch Logs連携 |

イメージタグはGitコミット由来の固定タグを使用した。具体的なイメージURIとタグは`ecs.tf`を参照。現時点ではイメージダイジェストによる固定には変更していない。

### 8.2 `container_definitions = jsonencode(...)`

タスク定義の外側はHCL、コンテナ定義は`jsonencode`でECS APIが受け取れるJSON相当のデータへ変換する。

```hcl
container_definitions = jsonencode([
  {
    name      = "sprint6-app"
    essential = true
    portMappings = [
      {
        containerPort = 8080
        protocol      = "tcp"
      }
    ]
  }
])
```

実際の`ecs.tf`には、イメージURI、DB接続、SSMシークレット、CloudWatch Logsの設定も含めた。

### 8.3 登録結果の確認

```powershell
aws ecs describe-task-definition `
  --task-definition sprint6-app `
  --query "taskDefinition.{Family:family,Revision:revision,Status:status,ExecutionRole:executionRoleArn}" `
  --output json --region ap-northeast-1
```

確認結果（主要部）：

```json
{
  "Family": "sprint6-app",
  "Revision": 1,
  "Status": "ACTIVE",
  "ExecutionRole": "arn:aws:iam::237575223564:role/sprint6-ecs-task-execution-role"
}
```

**学び：** `ACTIVE`はタスク定義を利用できることを示し、コンテナが実際に起動しているという意味ではない。

---

## 9. ECSクラスターとサービスの構築

### 9.1 ECSクラスター

```hcl
resource "aws_ecs_cluster" "sprint6" {
  name = "sprint6-ecs-cluster"
}
```

クラスターはタスクやサービスをまとめる論理的な管理単位。クラスター作成だけではFargateタスクは起動しない。

### 9.2 ECSサービス

```hcl
resource "aws_ecs_service" "sprint6" {
  name            = "sprint6-app-service"
  cluster         = aws_ecs_cluster.sprint6.arn
  task_definition = aws_ecs_task_definition.sprint6.arn
  launch_type     = "FARGATE"
  desired_count   = 0

  network_configuration {
    subnets = [
      data.aws_subnet.public_a.id,
      data.aws_subnet.public_c.id
    ]

    security_groups = [
      aws_security_group.fargate.id
    ]

    assign_public_ip = true
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.sprint6.arn
    container_name   = "sprint6-app"
    container_port   = 8080
  }
}
```

上記は**検証後の停止状態を表す主要構成の抜粋**。作業時は先に`load_balancer`なしでサービスを作成し、その後ブロックを追加して既存サービスを`update in-place`した。

- `cluster`：サービスの所属先を指定。
- `task_definition`：利用するタスク定義のARN。
- `launch_type`：`FARGATE`。
- `desired_count`：ECSが維持しようとするタスク数。
- `network_configuration`：配置先サブネット、SG、パブリックIP割当。
- `load_balancer`：**どのターゲットグループに、どのコンテナの何番ポートを登録するか**を指定。

### 9.3 依存関係の理解

```hcl
cluster         = aws_ecs_cluster.sprint6.arn
task_definition = aws_ecs_task_definition.sprint6.arn
```

`aws_ecs_cluster.sprint6.arn`は、Terraformで管理しているクラスターのARNを参照する式。これによってARNの手入力を避けるとともに、Terraformが依存関係を把握できる。

`.tf`ファイルの上から順番にリソースを作るのではなく、**参照関係に基づいた依存グラフ**を使って構築順を決める。

### 9.4 `desired_count`の推移

| 段階 | Desired | Running（確認値） | 目的 |
|---|---:|---:|---|
| サービス初期構築 | 0 | 0 | 料金を抑えつつ構成を準備 |
| ALB接続後の起動テスト | 1 | 1 | 実タスクを起動して疎通検証 |
| 検証後の停止 | 0 | 0 | 不要なFargate稼働を止める |

`desired_count`を変更して`apply`しただけでは、ただちに`Running`が同値であるとは限らない。ECSの実際のタスク数をCLIで確認する必要がある。

---

## 10. ALBターゲットグループとリスナールール（`alb.tf`）

### 10.1 ターゲットグループの作成

```hcl
resource "aws_lb_target_group" "sprint6" {
  name        = "sprint6-app-tg"
  port        = 8080
  protocol    = "HTTP"
  target_type = "ip"
  vpc_id      = data.aws_vpc.existing.id

  health_check {
    enabled             = true
    path                = "/health"
    protocol            = "HTTP"
    matcher             = "200"
    interval            = 30
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 2
  }
}
```

- `target_type = "ip"`：FargateタスクのIPアドレスをターゲットとして登録するために必要。
- `/health`：ALBがSpring BootのヘルスチェックAPIを呼び出す。
- `matcher = "200"`：HTTPステータス200を正常と判定。
- ターゲットグループは**宛先の一覧と健康状態**を管理する。スケーリングを実行する主体そのものではない。

### 10.2 既存ALBリスナーへのルール追加

```hcl
resource "aws_lb_listener_rule" "sprint6" {
  listener_arn = data.aws_lb_listener.existing.arn
  priority     = 2

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.sprint6.arn
  }

  condition {
    http_header {
      http_header_name = "X-Environment"
      values           = ["sprint6"]
    }
  }
}
```

このルールは、リクエストのHTTPヘッダーに次の組み合わせがある場合に適用される。

```http
X-Environment: sprint6
```

- **ヘッダー名**：`X-Environment`
- **ヘッダー値**：`sprint6`
- **一致時のアクション**：`sprint6-app-tg`への`forward`
- **評価優先順位**：`2`（数値が小さいルールほど優先。既存ルールとの重複は作成前後に確認）

ヘッダーが一致しない場合、別のリスナールールやデフォルトアクションが評価される。

### 10.3 AWS CLIによるルールの確認

```powershell
aws elbv2 describe-rules `
  --listener-arn "<既存HTTPリスナーARN>" `
  --query "Rules[?Priority=='2'].{Priority:Priority,Conditions:Conditions,Actions:Actions}" `
  --output json --region ap-northeast-1
```

実際に確認した値：

```text
Priority        = "2"
HttpHeaderName  = "X-Environment"
Values          = ["sprint6"]
Action.Type     = "forward"
TargetGroup     = sprint6-app-tg
```

### 10.4 ECSサービスとターゲットグループの関連付け

```hcl
load_balancer {
  target_group_arn = aws_lb_target_group.sprint6.arn
  container_name   = "sprint6-app"
  container_port   = 8080
}
```

タスク定義にある`name = "sprint6-app"`と`containerPort = 8080`に一致させる。ここは新しいコンテナ名やポートを決める場所ではなく、**定義済みコンテナの接続対象を指定する場所**。

この変更のPlan：

```text
# aws_ecs_service.sprint6 will be updated in-place
+ load_balancer { ... }
Plan: 0 to add, 1 to change, 0 to destroy.
```

**学び：** 既存サービスを削除・再作成せずにロードバランサー関連付けだけ追加できた。

---

## 11. RDS起動からFargate起動・疎通確認まで

### 11.1 RDSの状態確認と起動

まず既存RDSの状態を確認。実際には停止中だったため、AWS CLIで起動した。

```powershell
aws rds describe-db-instances `
  --db-instance-identifier sprint2-postgres `
  --query "DBInstances[0].DBInstanceStatus" `
  --output text --region ap-northeast-1
```

```powershell
aws rds start-db-instance `
  --db-instance-identifier sprint2-postgres `
  --region ap-northeast-1
```

観測した状態遷移：

```text
stopped -> starting -> available
```

対象DBの主要情報：

- インスタンス識別子：`sprint2-postgres`
- エンジン：PostgreSQL（停止操作時の表示は`18.3`）
- インスタンスクラス：`db.t4g.micro`
- DB名：`sprint2db`
- ポート：`5432`
- パブリックアクセス：`false`
- DBサブネットグループ：`sprint2-db-subnet-group`

`available`はRDSインスタンスが利用可能な状態であることを示すが、**アプリからのDB接続成功までを保証するものではない**。

### 11.2 Fargateの起動

`ecs.tf`のECSサービスについて、次のように変更した。

```diff
- desired_count = 0
+ desired_count = 1
```

`terraform plan`で`0 to add, 1 to change, 0 to destroy`を確認し、`terraform apply`。

```text
Apply complete! Resources: 0 added, 1 changed, 0 destroyed.
```

- `1 changed`は**既存のECSサービスを1件変更**したという意味。
- `1 added`は「Fargateタスクが1個起動した」という意味ではない。
- 起動したかどうかは、AWSのECSサービス・タスク情報で別途検証する。

### 11.3 ECSサービスの状態確認

```powershell
aws ecs describe-services `
  --cluster sprint6-ecs-cluster `
  --services sprint6-app-service `
  --query "services[0].{Status:status,Desired:desiredCount,Running:runningCount,Pending:pendingCount}" `
  --output json --region ap-northeast-1
```

観測結果：

```json
{
  "Status": "ACTIVE",
  "Desired": 1,
  "Running": 1,
  "Pending": 0
}
```

- `Desired`：ECSサービスが維持したいタスク数。
- `Running`：実際に稼働しているタスク数。
- `Pending`：起動処理中のタスク数。
- `Running=1`はコンテナの実行状態を示すが、HTTPやDBの正常性を直接保証するわけではない。

### 11.4 ALBのターゲットヘルス確認

```powershell
aws elbv2 describe-target-health `
  --target-group-arn "<Sprint 6ターゲットグループARN>" `
  --query "TargetHealthDescriptions[*].{IP:Target.Id,Port:Target.Port,State:TargetHealth.State,Reason:TargetHealth.Reason}" `
  --output table --region ap-northeast-1
```

実際の結果：

```text
IP        Port   Reason   State
10.1.4.55 8080   None     healthy
```

この結果により、ALBがSprint 6のFargateタスクへヘルスチェックを送り、`/health`で期待するHTTP 200を得られていると判断できた。

### 11.5 実際のALB DNS取得

```powershell
aws elbv2 describe-load-balancers `
  --names sprint3-alb `
  --query "LoadBalancers[0].DNSName" `
  --output text --region ap-northeast-1
```

取得したDNS名：

```text
sprint3-alb-632878014.ap-northeast-1.elb.amazonaws.com
```

※ 上記は2026-10-11の実測値。別の環境へ再構築するときはDNS名を再取得する。

### 11.6 `/health` のエンドツーエンド検証

```powershell
curl.exe -i -H "X-Environment: sprint6" "http://sprint3-alb-632878014.ap-northeast-1.elb.amazonaws.com/health"
```

**実測レスポンス：**

```http
HTTP/1.1 200
Content-Type: text/plain;charset=UTF-8
Content-Length: 2

OK
```

確認できたこと：

1. 手元のPCからALBのHTTP:80へアクセスできた。
2. ALBリスナールールの`X-Environment: sprint6`条件に一致した。
3. Sprint 6ターゲットグループに振り分けられた。
4. Fargate上のSpring Bootの`/health`から正常なHTTPレスポンスが返った。

### 11.7 `/records` によるRDS接続の検証

```powershell
curl.exe -i -H "X-Environment: sprint6" "http://sprint3-alb-632878014.ap-northeast-1.elb.amazonaws.com/records"
```

**実測レスポンス：**

```http
HTTP/1.1 200
Content-Type: application/json
Content-Length: 272

[{"id":5,"memo":"Sprint4 EC2 test","topic":"Docker"},{"id":4,"memo":"baseline","topic":"Sprint3"},{"id":3,"memo":"テストです","topic":"Java"},{"id":2,"memo":"lsコマンドを学習","topic":"Linux"},{"id":1,"memo":"CLIからAPIを呼び出した","topic":"AWS CLI"}]
```

**5件のレコードを取得できた。**

これは単なるコンテナ起動確認ではなく、

```text
PC -> ALB -> ターゲットグループ -> Fargate上のSpring Boot
   -> RDS/PostgreSQL -> JSONレスポンス -> PC
```

という一連の通信が機能したことを示す、Sprint 6の最重要の検証結果。

> `/health`だけが正常でも、DB認証やDBネットワークが壊れていれば`/records`は失敗する可能性がある。Sprint 3でも、ALBヘルスチェックはHealthyでもDB依存のAPIが500になる事象を経験した。今回、**DBに依存するAPIまで確認したこと**に意味がある。

---

## 12. 作業後の安全な停止と最終状態

### 12.1 Fargateタスクを0個へ戻す

`ecs.tf`：

```diff
- desired_count = 1
+ desired_count = 0
```

`plan`の内容を確認してから`apply`し、CLIで停止を検証。

```powershell
aws ecs describe-services `
  --cluster sprint6-ecs-cluster `
  --services sprint6-app-service `
  --query "services[0].{Desired:desiredCount,Running:runningCount,Pending:pendingCount}" `
  --output json --region ap-northeast-1
```

**実測結果：**

```json
{
  "Desired": 0,
  "Running": 0,
  "Pending": 0
}
```

Fargateタスクは停止確認済み。ECSサービス、クラスター、関連設定そのものは残した。

### 12.2 RDSの停止

```powershell
aws rds stop-db-instance `
  --db-instance-identifier sprint2-postgres `
  --region ap-northeast-1
```

停止要求直後の状態：`stopping`。続いて、

```powershell
aws rds describe-db-instances `
  --db-instance-identifier sprint2-postgres `
  --query "DBInstances[0].DBInstanceStatus" `
  --output text --region ap-northeast-1
```

を実行し、**`stopped`になったことを確認**した。

### 12.3 コスト面の注意

- Fargateタスクの実行時間に応じた料金は、タスクを停止すれば以降の実行分は発生しなくなる。
- RDSを停止してもストレージ・バックアップ等に関連する費用は残ることがある。
- 停止したRDSは、通常最大7日程度で自動再起動されるため、継続的な料金確認が必要。
- **既存ALBなど、停止していないAWSリソースの利用料金は引き続き発生し得る。**
- 本記録では**実際のAWS請求額の最終確認までは完了していない**。AWS Billing / Cost Explorer / Budgetsで確認すること。

---

## 13. 実作業で深まった理解・重要な気づき

### 13.1 HCLは命令の羅列ではなく、望ましい構成の宣言

```hcl
resource "aws_ecs_cluster" "sprint6" {
  name = "sprint6-ecs-cluster"
}
```

「作成コマンドを今すぐ実行する」ではなく、Terraformに「このリソースをこの内容で管理する」と宣言する。実際の変更は`plan`で確認し、`apply`で反映する。

### 13.2 `.tf`ファイルはディレクトリ単位で1つの構成になる

`ecs.tf`の一番上に書いたリソースが先に作られるわけではない。`main.tf`、`iam.tf`、`alb.tf`など同じディレクトリの設定が統合され、参照関係に応じて実行順序が決まる。

### 13.3 `.arn`・`.id`・`.name`を使い分ける

```hcl
cluster          = aws_ecs_cluster.sprint6.arn
vpc_id           = data.aws_vpc.existing.id
target_group_arn = aws_lb_target_group.sprint6.arn
```

リソースを参照する際は、AWS APIの設定項目が要求する識別子の種類を確認する。ARNはAWSの標準化されたリソース識別子の一種。

### 13.4 ターゲットグループは可変IPに対応する仕組み

Fargateタスクは再起動やスケール変更でIPが変わる可能性がある。ECSサービスをターゲットグループに接続することで、ECSがタスクの登録・解除を管理し、ALBは正常なターゲットへ転送する。

**ただし、今回試したのは希望タスク数0→1→0の変更であり、オートスケーリングポリシー自体は実装していない。**

### 13.5 ECSのクラスターとサービスは所属関係にある

```powershell
aws ecs describe-services --cluster sprint6-ecs-cluster --services sprint6-app-service
```

異なるクラスターに同名のECSサービスが存在し得るため、対象クラスターを明示する。`--cluster`を省略すると通常は`default`クラスターが対象となる。

### 13.6 AWS CLIのJSONと`--query`（JMESPath）

```json
{
  "services": [
    {
      "serviceName": "sprint6-app-service",
      "desiredCount": 0,
      "runningCount": 0,
      "pendingCount": 0
    }
  ]
}
```

- `services`：サービスの配列。
- `services[0]`：その配列の1番目の**サービスオブジェクト全体**。
- `services[0].runningCount`：1番目のサービスの`runningCount`属性。
- `services[0].{Desired:desiredCount,Running:runningCount}`：必要な値だけ抽出し、表示名を付け直す。

`[]`は配列、`{}`は項目と値を持つオブジェクトという構造が理解できた。

### 13.7 コンソール・Terraform・CLI・CloudWatchの役割分担

| ツール | 特に有効な用途 |
|---|---|
| Terraform | AWS構成の宣言、差分レビュー、再現性のある変更、設定のGit管理 |
| AWS CLI | 現状調査、具体的なAPI操作、動作検証、スクリプト化 |
| AWSマネジメントコンソール | 新サービスの探索、設定の可視化、デプロイ状況の直感的な把握 |
| CloudWatch | アプリログ、メトリクス、アラーム、障害調査 |
| CloudTrail | AWS APIの操作履歴の確認 |

今後は「コンソールで手作業構築すること」だけでなく、**コードで構築し、CLI・コンソール・監視サービスで意図どおりの動作を検証する**運用へ発展させていく。

---

## 14. Git管理・GitHub Actionsの確認

### 14.1 `.gitignore`

追加・確認したTerraform用ルール：

```gitignore
### Terraform ###
.terraform/
*.tfstate
*.tfstate.*
*.tfvars
*.tfvars.json
*.tfplan
crash.log
crash.*.log
```

- `.terraform/`：ダウンロードしたProviderや作業用データを除外。
- `*.tfstate*`：Stateやバックアップを除外。Stateには秘密値などが含まれ得る。
- `*.tfvars`・`*.tfvars.json`：変数値ファイルの誤Pushを防止。
- `.terraform.lock.hcl`：Providerの再現性のため**Git管理対象とする**。
- ほかにも将来の設定に応じて、Terraformの保存済みPlan、認証情報、秘密値が含まれないかPush前に再点検する。

確認コマンド：

```powershell
git status --short
git status --short --untracked-files=all
git diff -- ../../.gitignore
```

観測した未追跡ファイル：

```text
 M ../../.gitignore
?? .terraform.lock.hcl
?? alb.tf
?? data.tf
?? ecs.tf
?? iam.tf
?? main.tf
?? providers.tf
?? security-group.tf
?? versions.tf
```

**重要：** これらはファイルがPC上に存在することを示しており、GitHubへPush済みであることを意味しない。`??`はGitで未追跡という意味。

### 14.2 GitHub Actionsの実行トリガー

既存ワークフロー：

```text
.github/workflows/
├── ci.yml
└── container-build.yml
```

`container-build.yml`で確認した実行条件：

```yaml
on:
  push:
    branches:
      - master
    paths:
      - 'src/**'
      - 'pom.xml'
      - 'mvnw'
      - '.mvn/**'
      - 'Dockerfile'
      - '.dockerignore'
```

このため、**`infra/sprint6/**`や`docs/**`のみのPushではDockerビルド・ECR Pushは起動しない構成**。当初検討した`paths-ignore`の追加は、このワークフローでは不要と判断した。

`ci.yml`の冒頭で確認したトリガー：

```yaml
on:
  workflow_dispatch:
```

`workflow_dispatch`は手動実行用。通常のPushでは実行されない。手動実行UIで扱うにはワークフローファイルがデフォルトブランチ上に存在する必要がある。

作業時のVS Code左下に表示されていたブランチ名：`sprint6-terraform`（末尾`*`は未コミット変更ありを示す）。

### 14.3 GitHub保存前チェックリスト（未実施部分）

- [ ] `docs/sprint-6.md`をリポジトリの`docs/`に保存する。
- [ ] `git status --short --untracked-files=all`で変更対象を再確認する。
- [ ] State、Providerの作業用ディレクトリ、秘密値、不要なPlanファイルがステージング対象に含まれていないことを確認する。
- [ ] `ecs.tf`の最終`desired_count = 0`を確認する。
- [ ] `terraform fmt -check`と`terraform validate`で最終構成を検証する。
- [ ] 必要に応じて`terraform plan`で差分を最終確認する（AWS認証が必要）。
- [ ] ドキュメント、Terraformコード、`.gitignore`をステージングして差分をレビューする。
- [ ] Sprint 6用ブランチでコミットし、GitHubへPushする。
- [ ] GitHub Actionsの不要な実行が発生していないか確認する。

---

## 15. トラブルシューティング・設計上の注意

今回の実作業で経験・確認した事項、およびその結果を踏まえた注意点を整理する。

| 事象・疑問 | 確認したこと / 対応 |
|---|---|
| Terraformのログが長い | `Reading...`は`data`読み込み、`Refreshing state...`は管理中リソースの実状態取得。変更対象は最終的なPlanの差分で判断する。 |
| `plan`が`1 to add`ではなく`1 to change` | 既存ECSサービスに`load_balancer`を追加したため、`update in-place`で更新された。 |
| `known after apply`が多い | AWSによる作成・登録後に確定する値なので異常ではない。 |
| `container_name`と`container_port`の指定 | その場で任意に決めるのではなく、ECSタスク定義内のコンテナ名・ポートと一致させる。 |
| `desired_count=1`なのにHTTPが返らない可能性 | タスクの`Running`、ALBターゲットの`healthy`、アプリAPI、DB接続を段階的に確認する。 |
| `/health`が正常でもDBが不調になる | `/records`などDB依存APIでも確認する。 |
| GitでTerraformファイルが見えない | `git status --short --untracked-files=all`で未追跡ファイルを個別表示する。 |
| `.gitignore`の差分表示に`(END)` | Gitのページャー。`q`で抜ける。`No newline at end of file`は末尾改行がないという表示。 |

### 本番設計と異なる点

- 本Sprintは学習環境であり、Fargateタスクを**パブリックサブネット＋パブリックIP割当**で実行した。本番ではプライベートサブネット、VPCエンドポイントやNAT、公開経路の制御などを要件に応じて検討する。
- ALBへの疎通検証はHTTPで実施した。本番向けにはHTTPS/TLS、証明書、必要に応じてWAFなどを考慮する。
- Fargate SGのアウトバウンドは広く許可している。宛先制限・運用負荷・必要なAWSサービスとの通信のバランスを検討する。
- リスナールールのHTTPヘッダーは振り分け条件であり、**認証やアクセス制御の代わりにはならない**。
- 本Sprintでは1タスクによる疎通を確認したが、実際のマルチAZ耐障害性やECSオートスケーリングの検証は未実施。
- SSMパラメータを使い平文パスワードをHCLに書かなかったが、パラメータのアクセス制御やローテーション、機密情報取り扱いは引き続き重要。

---

## 16. 未実施事項と次の発展課題

Sprint 6で実施した内容と混同しないよう、ここからは**今後の候補**として記載する。

### 16.1 Sprint 6の締め作業

1. 実際のAWS料金をBilling / Cost Explorer / Budgetsで確認する。
2. この`docs/sprint-6.md`を最終確認し、実際の`infra/sprint6/*.tf`と矛盾がないかチェックする。
3. TerraformコードとドキュメントをGitHubにコミット・Pushする。
4. Actionsの実行状況とGitの状態を確認する。

### 16.2 Terraformの運用改善

- **Remote State**：S3バックエンドへの移行と、複数人でのState共有・排他制御を学習する。今回のStateはローカル管理。
- **モジュール化**：ECSサービス・IAM・ネットワークなどの共通部分を再利用できる形にする。
- **変数化**：アカウント依存のARN、VPC・サブネットID、コンテナイメージURI、環境名などを環境ごとに扱いやすくする。
- **CI/CD**：PR時の`fmt`・`validate`・`plan`、承認後の`apply`などを検討する。Terraform Applyの自動実行は本Sprintでは実施していない。
- **ドリフト検知**：定期Planなどによる意図しない変更の早期発見を考える。
- **イメージの固定**：タグに加えてdigest指定の必要性を検討する。

### 16.3 AWS・DevOpsの発展

- ECS Service Auto Scaling、ヘルスチェック失敗時の復旧、複数AZでの運用を検証する。
- CloudWatchのログ・メトリクス・アラームを体系的に設計する。
- IAM最小権限、ネットワーク隔離、HTTPS化、監視・運用コストを見直す。
- 将来のSprintでS3/Route 53、サーバーレス、CI/CD、メッセージングなどへ応用する。
- 必要に応じてEKS/KubernetesやGPUワークロードの基礎へ発展させる。

---

## 17. Sprint 6の総括

今回最大の成果は、単にTerraformのコマンドを覚えたことではない。

**設計 → HCLで宣言 → Planレビュー → Apply → AWS CLIで状態確認 → 実際のアプリ通信検証 → 停止 → Gitで成果を管理**

という、クラウドエンジニアの一連の仕事を小規模システムで再現できた点にある。

特に、

- `data`と`resource`の違いを理解し、既存VPC・ALB・RDSを再利用した。
- `resource.arn`等の参照を使って、AWSリソース間の依存関係をコードで表現した。
- `plan`に表示される`create`と`update in-place`を読み分けられるようになった。
- タスク起動（ECS）、ALBからの到達性（ヘルスチェック）、アプリ応答、DB接続を**別々の検証項目**として確認した。
- `/records`でPostgreSQLのデータ5件を取り出し、ALB→Fargate→RDSの実際の疎通を証明した。
- 検証後、FargateとRDSの停止を確認し、コストへの配慮を実践した。

今後は、AIを使ってHCLの作成を効率化しつつ、構築されたインフラが**要件・可用性・セキュリティ・コスト・運用性**に適合しているかを自分で判断・検証できる力を伸ばしていく。

### 最終チェック

- **技術目標：達成**
- **エンドツーエンド検証：成功**
- **Fargate/RDS停止：確認済み**
- **GitHub保存・最終コスト確認：これから**

> この記録は実際の作業ログと会話上で確認した内容に基づく。リポジトリのファイル内容を直接監査したものではないため、GitHubへ公開・Pushする前に、現物のTerraformコード・ID・設定・秘密情報の混入を最終チェックすること。
