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


## Next

- AWS　EC2へデプロイ
- Linux上でSpring Bootを起動
- Port / Security Group /HTTPを学ぶ
- Cloudwatchによる監視
- CI/CD