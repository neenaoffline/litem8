# litem8

A simple, single-binary SQLite migration tool written in Zig.

## Features

- **Single binary** — No runtime dependencies, statically linked with SQLite
- **Up migrations only** — No down migrations, keeping things simple
- **Hash verification** — Detects if already-run migrations have been modified
- **Gap detection** — Prevents inserting new migrations between already-run ones
- **Transaction per migration** — Each migration runs in its own transaction with rollback on failure

## Installation

### Download Pre-built Binary

Download from [GitHub Releases](https://github.com/neenaoffline/litem8/releases):

| Platform | Static Binary | Dynamic Binary |
|----------|--------------|----------------|
| Linux x86_64 | `litem8-linux-x86_64-static` | `litem8-linux-x86_64-glibc` |
| Linux ARM64 | `litem8-linux-aarch64-static` | `litem8-linux-aarch64-glibc` |
| Linux ARM | `litem8-linux-arm-static` | — |
| Alpine x86_64 | `litem8-linux-x86_64-static` | `litem8-linux-x86_64-musl` |
| Alpine ARM64 | `litem8-linux-aarch64-static` | `litem8-linux-aarch64-musl` |
| macOS Intel | `litem8-macos-x86_64` | — |
| macOS Apple Silicon | `litem8-macos-aarch64` | — |
| Windows x64 | `litem8-windows-x86_64.exe` | — |
| Windows ARM64 | `litem8-windows-aarch64.exe` | — |

**Static binaries** bundle SQLite and work anywhere. **Dynamic binaries** are smaller but require `libsqlite3` on your system.

### Other Installation Methods

```bash
# Nix
nix run github:neenaoffline/litem8 -- --help

# Docker
docker run --rm -v $(pwd):/data ghcr.io/neenaoffline/litem8 \
  up --db /data/app.db --migrations /data/migrations

# Build from source (requires Zig 0.15.2+)
git clone https://github.com/neenaoffline/litem8.git
cd litem8 && zig build -Doptimize=ReleaseSafe
./zig-out/bin/litem8 --help
```

## Usage

```bash
# Run pending migrations
litem8 up --db app.db --migrations ./migrations

# Check status
litem8 status --db app.db --migrations ./migrations

# Custom table name (default: schema_migrations)
litem8 up --db app.db --migrations ./migrations --table my_migrations
```

## Migration Files

Files must be named `<number>_<name>.sql`:

```
migrations/
├── 001_create_users.sql
├── 002_add_posts.sql
└── 003_add_indexes.sql
```

Example migration:

```sql
-- migrations/001_create_users.sql
CREATE TABLE users (
    id INTEGER PRIMARY KEY,
    email TEXT NOT NULL UNIQUE,
    created_at TEXT DEFAULT CURRENT_TIMESTAMP
);
```

## How It Works

1. Migrations are tracked in `schema_migrations` table with name, timestamp, and SHA256 hash
2. On `up`, litem8 verifies hashes of already-run migrations haven't changed
3. Each migration runs in a transaction — failure triggers rollback
4. New migrations must have numbers greater than all previously-run ones (gap detection)

## License

MIT
