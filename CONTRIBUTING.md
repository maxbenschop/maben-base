# Contributing to Maben Base

Thanks for helping. This page explains how changes get from an idea into a release.

## How the code flows

```
your fork / branch ──PR──▶ main ──release.sh──▶ tag vX.Y.Z + GitHub release
```

- **`main`** is always releasable. Every change arrives through a pull request.
- **Branches** are short-lived and named after what they do: `fix/mysql-bit-columns`, `feature/sql-server`, `docs/ssh-tunnels`. One topic per branch.
- **Releases** are tags `vX.Y.Z` on `main`, created only by the maintainer.

Found a bug or have an idea? Open an issue first if you're not sure it fits; small fixes can go straight to a pull request. Security problems go through `SECURITY.md`, not an issue.

## Making a change

1. Fork the repository (or, if you have write access, create a branch).
2. Build with `swift build`. `./build.sh demo` opens the app on a sample SQLite database without touching your saved connections.
3. Run `swift test`. The server tests are skipped unless you point them at real databases (below).
4. If you change a driver or the SQL that edits rows, run the server tests against Postgres and MySQL (and MariaDB if you touched MySQL), plus the engine you changed.
5. If people will notice the change, add a line under the top section of `CHANGELOG.md`. Don't change the version in `Info.plist`; that happens when releasing.
6. Open a pull request into `main` and fill in the template.

## What a pull request needs before it's merged

These are enforced by the repository rules on `main`:

- The **Build and test** check passes (GitHub Actions: debug and release build, the tests, the command-line tool against SQLite, scripts, changelog). CI has no database servers, so say in the pull request which server tests you ran yourself.
- One approving review from a code owner (`.github/CODEOWNERS`).
- All review conversations resolved.
- Merged with **squash**, so `main` has one commit per pull request and a straight history. The branch is deleted after merging.
- No force pushes to `main`, and `main` can't be deleted.

Tags matching `v*` can only be created, moved or deleted by repository admins, so only the maintainer can release.

## Testing against real servers

Docker gives you throwaway servers on unusual ports. Each test is skipped unless its URL is set.

```sh
docker run -d --name mb-pg      -e POSTGRES_PASSWORD=secret -p 55432:5432 postgres:17
docker run -d --name mb-my      -e MYSQL_ROOT_PASSWORD=secret -e MYSQL_DATABASE=shop -p 53306:3306 mysql:8.4
docker run -d --name mb-maria   -e MARIADB_ROOT_PASSWORD=secret -e MARIADB_DATABASE=shop -p 53307:3306 mariadb:11
docker run -d --name mb-redis   -p 56379:6379 redis:7 redis-server --requirepass secret
docker run -d --name mb-mongo   -e MONGO_INITDB_ROOT_USERNAME=root -e MONGO_INITDB_ROOT_PASSWORD=secret -p 57017:27017 mongo:8
docker run -d --name mb-click   -e CLICKHOUSE_USER=mb -e CLICKHOUSE_PASSWORD=secret -p 58123:8123 clickhouse/clickhouse-server
docker run -d --name mb-libsql  -p 58080:8080 ghcr.io/tursodatabase/libsql-server
docker run -d --name mb-mssql   --platform linux/amd64 -e ACCEPT_EULA=Y -e MSSQL_SA_PASSWORD=Secret_pw_1 -p 51433:1433 mcr.microsoft.com/mssql/server:2022-latest
docker run -d --name mb-oracle  -e ORACLE_PASSWORD=Secret_pw_1 -e APP_USER=mb -e APP_USER_PASSWORD=Secret_pw_1 -p 51521:1521 gvenzl/oracle-free:slim-faststart
docker run -d --name mb-cassandra -p 59042:9042 -e MAX_HEAP_SIZE=512M -e HEAP_NEWSIZE=128M cassandra:5
docker run -d --name mb-bq      --platform linux/amd64 -p 59050:9050 ghcr.io/goccy/bigquery-emulator --project=mbproj --dataset=shop
brew install duckdb

MB_TEST_POSTGRES='postgres://postgres:secret@127.0.0.1:55432/postgres?sslmode=disable' \
MB_TEST_MYSQL='mysql://root:secret@127.0.0.1:53306/shop' \
MB_TEST_REDIS='redis://:secret@127.0.0.1:56379/1' \
MB_TEST_MONGO='mongodb://root:secret@127.0.0.1:57017/shop?authSource=admin' \
MB_TEST_CLICKHOUSE='clickhouse://mb:secret@127.0.0.1:58123/default' \
MB_TEST_LIBSQL='libsql://127.0.0.1:58080' \
MB_TEST_DUCKDB='duckdb:///tmp/mb-test.duckdb' \
MB_TEST_SQLSERVER='sqlserver://sa:Secret_pw_1@127.0.0.1:51433/master' \
MB_TEST_CASSANDRA='cassandra://127.0.0.1:59042/mb' \
MB_TEST_BIGQUERY='bigquery://mbproj/shop?endpoint=http://127.0.0.1:59050' \
swift test
```

Cassandra needs the keyspace first: `swift run BaseTool query 'cassandra://127.0.0.1:59042/' "CREATE KEYSPACE mb WITH replication = {'class': 'SimpleStrategy', 'replication_factor': 1}"`.

Oracle runs through sqlplus. Without Instant Client on your Mac, point the driver at the container's: a script with `exec docker exec -i mb-oracle sqlplus "$@"`, then `MB_TEST_ORACLE='oracle://mb:Secret_pw_1@localhost:1521/FREEPDB1?tool=/path/to/that/script'`.

The tests create and drop their own tables. They browse, filter (number columns included) and save edits with awkward values through the same text the app writes; the Postgres and MySQL ones also check structure changes, the server window's SQL, rollback, cancel, and switching database.

TLS by hand: `swift run BaseTool query 'postgres://…?sslmode=verify-full&sslrootcert=ca.crt&sslcert=client.p12&sslpassword=…' 'select 1'`. SSH: `swift run BaseTool ssh user@host:22 password:… <url> <sql>` or `passphrase:<secret>:<key file>`; `MB_SSH_DEBUG=1` shows what ssh says.

## Rules that keep data safe

- Nothing is written without the user saving, and staged edits go in one transaction.
- An UPDATE or DELETE that matches no row stops the save and rolls back.
- Edits find rows by primary key only. Without one, the table is read-only.
- Production connections ask first, and read-only connections never write.
- A certificate is only skipped when the user chose TLS Require.

A change that touches one of these comes with a test that shows the rule still holds.

## Releasing (maintainer)

Releases are tags `vX.Y.Z` on `main`. `./release.sh` builds a universal app, signs it with the Developer ID and has Apple notarize it, then writes `dist/Maben-Base.dmg` and `.zip`. Add an entry to `CHANGELOG.md` and bump `CFBundleShortVersionString` in `Info.plist` first.

## Style

- Swift: follow the code around you. Comments explain why, not what.
- No dependencies: drivers are written for this app, in one file per engine in `Sources/BaseCore`.
- User-facing text: short, plain sentences, sentence case, no jargon.

## Code of conduct

Be kind and assume good intent. Harassment isn't tolerated.
