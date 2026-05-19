# 10 — CLI scaffolder

`verve-cli` writes a self-contained starter project. The entire Verve
source tree is embedded into the binary at build time via `@embedFile`;
`verve-cli new <dir>` lays it out as a regular Zig package.

## Build

```sh
zig build              # in the Verve repo
# zig-out/bin/verve-cli is now built
```

## Usage

```sh
verve-cli new <target-dir> [--name <pkg-name>]
```

- `<target-dir>` — must not exist or must be empty. The scaffolder
  refuses to write over existing files.
- `--name NAME` — Zig identifier (a-z, A-Z, 0-9, `_`; no leading
  digit). Defaults to the basename of the target directory.

```sh
./zig-out/bin/verve-cli new ~/code/my-app
# info(verve-cli): scaffolded 'my-app' into /Users/.../my-app
# info(verve-cli): next:
#   cd /Users/.../my-app
#   zig build
#   ./zig-out/bin/verve-server
```

If your directory name isn't a valid Zig identifier (e.g.
`my-cool-app`), pass `--name`:

```sh
verve-cli new my-cool-app --name=my_cool_app
```

## What gets written

```
my-app/
├── build.zig                      ← framework's build pipeline, unmodified
├── build.zig.zon                  ← fresh, with your --name and a valid fingerprint
├── LICENSE
├── src/
│   ├── verve.zig
│   ├── core/{node,signal,context,renderer}.zig
│   ├── server/{main,api_handler,router,pool,metrics,gzip,tests}.zig
│   ├── client/{main,signal,dom,allocator,render,tests}.zig
│   ├── bridge/verve.js
│   ├── cli/main.zig
│   └── app/{components,api,routes}.zig
└── tests/
    ├── integration.zig
    └── public_fixture/{hello.txt,style.css}
```

The scaffolded `src/app/` contains the framework's example app
(Counter + TodoList). Treat it as a starter — rip it apart and replace
with your own components / actions / routes.

## The fingerprint dance

`build.zig.zon` carries a `.fingerprint` field that Zig validates: the
high 32 bits are derived from the package name, the low 32 bits are
random. If a fingerprint doesn't match, `zig build` refuses to compile
and suggests the correct value.

The scaffolder handles this by:

1. Writing `build.zig.zon` with a placeholder fingerprint (`0x...`).
2. Spawning `zig build` in the target directory, capturing stderr.
3. Parsing the `use this value: 0x...` suggestion.
4. Rewriting `build.zig.zon` with the suggested value.

You see one line of warning if zig isn't on the PATH or the probe
fails. In that case, run `zig build` yourself, copy the suggested
value from the error message, paste into `build.zig.zon`.

## Customizing the starter

After scaffolding, the most common edits:

- **`src/app/components.zig`** — replace the inline CSS, redesign the
  starter pages.
- **`src/app/api.zig`** — delete the example actions; declare your own.
- **`src/app/routes.zig`** — replace the route table.
- **`tests/integration.zig`** — point the integration test fixtures at
  your own routes (or delete the file if you don't need this style of
  test).

The framework code under `src/core/`, `src/server/`, `src/client/`,
`src/bridge/` is the framework itself — you can edit it if you want
custom behavior, but the simpler workflow is to leave it alone and
upgrade by overlaying a newer copy from a fresh `verve-cli new`.

## Updating the framework in an existing project

The framework is vendored into your project tree. To upgrade:

```sh
# In a scratch dir:
verve-cli new /tmp/fresh
# Diff:
diff -r /tmp/fresh/src/server   ~/code/my-app/src/server
diff -r /tmp/fresh/src/core     ~/code/my-app/src/core
diff -r /tmp/fresh/src/client   ~/code/my-app/src/client
diff -r /tmp/fresh/src/bridge   ~/code/my-app/src/bridge
diff -r /tmp/fresh/build.zig    ~/code/my-app/build.zig
# Apply the diffs you want.
```

This pattern keeps your `src/app/` and `tests/` untouched while picking
up framework fixes. No package manager involved; no dependency hash
to track.

## Why embed rather than depend on a remote URL?

HANDOFF-level decision: Zig's package manager is still maturing, and a
self-contained scaffold is the safest workflow for early adopters. When
the package manager stabilizes, switching `verve-cli new` to emit a
`build.zig.zon` with a `dependencies.verve.url` entry is straightforward
— the change is local to `src/cli/main.zig:renderZon` and the
`renderZonWithFingerprint` helper.

## Diagnostics

```sh
verve-cli --help     # full usage
verve-cli            # also prints usage (no args)
verve-cli new        # also prints usage (missing target dir)
```

The CLI itself logs via `std.log.scoped(.@"verve-cli")` so the prefix
is distinct from the framework's `verve` scope.

## Next

- [11 — Deployment](11-deployment.md) — putting a scaffolded app into
  production.
- [Examples](../examples/README.md) — three running apps you can
  diff against your own.
