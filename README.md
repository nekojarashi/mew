# mew — Multiple Environment Worktrees

**mew** は、Git worktree と Docker Compose を使った**並行開発**のための汎用 CLI です。  
複数ブランチを同時に動かしたいときに、worktree ごとに別ポート・別 DB の web 環境を立ち上げ、インフラ（Postgres など）は共有します。

---

## 目的

- **複数ブランチの同時稼働**: 1 リポジトリで、main と複数 worktree を同時に起動し、それぞれ別 URL・別 DB で開発・検証する
- **設定ファイル不要**: 設定ファイルは使わず、既存の `docker-compose.yml` と `git worktree list` から設定を推測する
- **どのプロジェクトでも使える**: Docker Compose で web + db を持つプロジェクトであれば、そのまま mew で worktree 並行開発ができる

---

## 概要

- **コマンド**: 単一の `mew` コマンドにサブコマンドで機能を提供（`mew build` など）
- **配布**: 単一の Bash スクリプト + インストーラ（`install.sh`）。追加の設定ファイルは不要
- **前提**: `git` と `docker`（Docker Desktop 等）がインストールされていること
- **略称**: **M**ultiple **E**nvironment **W**orktrees

---

## 機能一覧

| サブコマンド            | 説明                                                                              |
| ----------------------- | --------------------------------------------------------------------------------- |
| `mew`（引数なし）       | ヘルプ（サブコマンド一覧）を表示                                                  |
| `mew build [branch...]` | 対話型で worktree を作成し、各 worktree で web を起動する（並行開発のメイン入口） |
| `mew rm`                | この worktree の web 停止・DB 削除                                                |
| `mew rm --all`          | 全 worktree の web 停止・DB 削除・worktree 削除（main で実行）                    |

---

## アーキテクチャ概要

mew は「main worktree」と「各 worktree」を区別し、main の `docker-compose.yml` で起動した **Postgres を 1 つ共有**し、worktree ごとに**別データベース**と**別ポートの web コンテナ**を割り当てます。worktree 用の compose 定義はファイルにせず、mew が **stdout に YAML を出力**し、`docker compose -f -` で読みます。

```
                    ┌─────────────────────────────────────────────────────────┐
                    │  main worktree（.git がディレクトリの worktree）          │
                    │  docker-compose.yml                                      │
                    │  ┌─────────┐  ┌─────────┐  ┌─────────┐                  │
                    │  │   db    │  │   web   │  │  minio  │  ...              │
                    │  │(Postgres)│  │ :3000   │  │ (任意)  │                  │
                    │  └────┬────┘  └─────────┘  └─────────┘                  │
                    │       │       DB: myapp                                   │
                    │       │                                                    │
                    └───────┼───────────────────────────────────────────────────┘
                            │ 同一 Postgres 内に worktree 用 DB を追加
                            │
        ┌───────────────────┼───────────────────┬───────────────────┐
        │                   │                   │                   │
        ▼                   ▼                   ▼                   ▼
  ┌───────────┐       ┌───────────┐       ┌───────────┐       ┌───────────┐
  │ myapp     │       │ myapp_feat_a │    │ myapp_feat_b │    │ myapp_wt  │
  │ (main DB) │       │ (worktree A)│    │ (worktree B)│    │ (worktree…)│
  └───────────┘       └───────────┘       └───────────┘       └───────────┘
        │                   │                   │                   │
        │                   │ host.docker.internal:5433 で接続       │
        │                   ▼                   ▼                   ▼
        │             ┌───────────┐       ┌───────────┐       ┌───────────┐
        │             │ web (A)   │       │ web (B)   │       │ web (…)   │
        │             │ :3101     │       │ :3102     │       │ :3xxx     │
        │             │ コード:   │       │ コード:   │       │ コード:   │
        │             │ worktree A│       │ worktree B│       │ worktree… │
        │             └───────────┘       └───────────┘       └───────────┘
        │                   │                   │                   │
        │                   └───────────────────┴───────────────────┘
        │                     mew が stdout に worktree 用 compose YAML を出力
        │                     → docker compose -f - で起動（ファイルは作らない）
        └─────────────────────────────────────────────────────────────────────
```

**ポイント**

- **main**: 従来どおり `docker compose up -d` で db / web / その他を起動。DB 名は `docker-compose.yml` の `POSTGRES_DB` 等から推測。
- **各 worktree**: mew が「web のみ」の compose 定義を stdout に出力し、`docker compose -f -` で起動。DB は main の Postgres に接続（`host.docker.internal`）し、worktree ごとの DB 名（例: `myapp_feat_a`）を使用。
- **設定の推測**: main のパスは `git worktree list` から、DB 名プレフィックス・ボリュームは `docker-compose.yml` から自動推測。必要に応じて環境変数で上書き可能。

### 構成図（Mermaid）

```mermaid
flowchart TB
  subgraph main["main worktree"]
    compose["docker-compose.yml"]
    db[(Postgres)]
    web_main["web :3000"]
    compose --> db
    compose --> web_main
    db --> db_main["DB: myapp"]
  end

  subgraph worktrees["worktrees（mew で起動）"]
    wt_a["worktree A<br/>web :3101"]
    wt_b["worktree B<br/>web :3102"]
    wt_n["worktree N<br/>web :3xxx"]
  end

  subgraph postgres_dbs["同一 Postgres 内の DB"]
    db_main
    db_a["myapp_feat_a"]
    db_b["myapp_feat_b"]
    db_n["myapp_..."]
  end

  db --> postgres_dbs
  wt_a -->|host.docker.internal| db_a
  wt_b -->|host.docker.internal| db_b
  wt_n -->|host.docker.internal| db_n

  mew["mew<br/>(stdout に YAML)"]
  mew -->|"docker compose -f -"| wt_a
  mew -->|"docker compose -f -"| wt_b
  mew -->|"docker compose -f -"| wt_n
```

---

## インストール

**このターミナルでインストールしてすぐ使う（シェルを再起動しない）:**

```bash
# source で実行すると、このシェルに PATH が反映され、その場で mew が使える
source <(curl -sSL https://raw.githubusercontent.com/OWNER/mew/main/install.sh)
```

インストールのみ（あとで `.bashrc` / `.zshrc` に PATH を追加するか、新しいターミナルを開く）:

```bash
curl -sSL https://raw.githubusercontent.com/OWNER/mew/main/install.sh | bash
```

**前提**: `git` と `docker` がインストールされていること。

`install.sh` 実行時には、`.zshrc` / `.bashrc` にシェルフックも追加されます。worktree 内では `docker compose` のまま入力すれば、自動で mew 用の compose に置き換わります（詳細は末尾の「シェルフックの仕組み」を参照）。

---

## 使い方

### 設定の決め方

**設定ファイルは使いません。**

1. **推測**: `docker-compose.yml` と `git worktree list` から main のパス・DB 名プレフィックス・ボリュームマウントを推測
2. **環境変数で上書き**: `MEW_MAIN_DIR`, `MEW_DB_NAME_PREFIX`, `MEW_ENV_FILE`, `MEW_WORKTREE_VOLUME`, `MEW_DB_SERVICE`, `MEW_WEB_SERVICE` など
3. **非対話**: `MEW_NON_INTERACTIVE=1` でプロンプトをスキップ（`build` 時はブランチ名を引数で指定）

### 想定するプロジェクト構成

- main の `docker-compose.yml` に `web` と `db` サービスがある
- worktree 用の compose 定義はファイルにせず、mew が stdout に出す YAML を `docker compose -f -` で渡す

### 実行例

```bash
# main で worktree を作成して web 起動
mew build feature-a feature-b

# 既存 worktree の web を起動したい場合は、main で mew build <branch> を再実行（既存なら web のみ起動）

# worktree 側で migrate など（docker compose と書けばシェルフックで自動置換される）
docker compose run --rm web pnpm db:migrate

# この worktree だけ片付け
mew rm

# main で全 worktree を削除
mew rm --all
```

### worktree 側での注意（Docker まわり）

worktree では **main の Docker 環境（Postgres や docker-compose の設定）を共有**しており、`docker compose` はシェルフックにより mew 用の compose に置き換わります。そのため、**`docker-compose.yml` や Dockerfile、docker まわりの設定を変更する作業は worktree では行わず、main で行う**ようにしてください。worktree 側でそれらを変更すると、main や他 worktree に影響したり、mew の推測がずれたりする可能性があります。

---

## リポジトリ構成

| ファイル     | 説明                                                     |
| ------------ | -------------------------------------------------------- |
| `mew`        | 単一の Bash スクリプト（全ロジックをこのファイルに含む） |
| `install.sh` | curl \| bash 用インストーラ（PATH に `mew` を配置）      |
| `README.md`  | 本ドキュメント                                           |

---

## シェルフックの仕組み

worktree では、`docker compose` をそのまま実行すると main の `docker-compose.yml` が参照され、main のコンテナが操作されてしまう。正しくは worktree 用の compose を扱う `mew compose` を実行する必要がある。しかし AI ツールやドキュメントは `docker compose` と書くことが多く、利用者やツールごとに書き分けるのは現実的ではない。そのため、**シェルレベルで `docker compose` を `mew compose` に透過的に置き換える**仕組みを用意している。

### 構成要素

1. **マーカー**: `mew build` が worktree を作成するときに、その worktree の git 内部領域（gitdir）に空ファイル `mew` を置く。これにより「この worktree は mew で作成された」と判定できる。
2. **シェルフック**: `docker` を関数として定義し、`docker compose` 実行時だけ PWD から上位に `.git` を辿り、worktree かつ gitdir に `mew` があれば `mew compose` に置き換えて実行する。それ以外は従来どおり `docker` を呼ぶ。
3. **マーカーの場所**: マーカーは worktree の作業ツリーには置かず、main 側の `.git/worktrees/<name>/mew`（gitdir 内）に置く。これにより `git status` に現れず、`git worktree remove` で消える。

### 判定フロー

```
docker compose ... が実行される
  │
  ├─ PWD から上位に .git を探す
  │
  ├─ .git がディレクトリ（main worktree）
  │   → 通常の docker をそのまま実行
  │
  ├─ .git がファイル（worktree）
  │   → gitdir パスを読み取り
  │   → gitdir/mew マーカーが存在する？
  │     ├─ YES → mew compose に置換して実行
  │     └─ NO  → 通常の docker をそのまま実行
  │
  └─ .git が見つからない
      → 通常の docker をそのまま実行
```

### フックの管理

フックは `install.sh` 実行時に `.zshrc` / `.bashrc` へ追加され、`# BEGIN mew hook` / `# END mew hook` で囲まれたブロックとして書かれる。手動で追加する場合は、`install.sh` 内の `emit_mew_hook` が出力するフックブロックを rc にコピーするか、`.zshrc` / `.bashrc` を作成したうえで `install.sh` を再実行する。`install.sh` を再実行すると既存のフックブロックは更新され、削除する場合は `# BEGIN mew hook` 〜 `# END mew hook` のブロックを rc から削除する。

---

## ライセンス

MIT
