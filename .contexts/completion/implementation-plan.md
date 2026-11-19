# Completion scripts: implementation plan

- **Source design:** `designs/completion.md` (normative; read it first).
- **Baseline:** commit `952ec84`, Zig 0.17.1, `zig build test` green (210 tests).
- **Scope:** add `CompletionShell`/`CompletionError`, the root-only `completion` entry point, the comptime level table,
  three shell emitters, M19 tests, the shell integration step, and docs. No parser, DSL, `View` layout, or normalization
  changes.

Where this plan and the design disagree, the design wins. The few details the design deliberately leaves open are fixed
in §9.

---

## 1. Baseline and working commands

Run these before touching anything, and after each milestone:

```sh
zig fmt --check src build.zig
zig build test
zig test src/dap.zig
```

The last two must stay green throughout. After the build step exists:

```sh
zig build completion-test
```

`zig build test` must never depend on `completion-test` and must never spawn a shell. Keep that split hard: M19 is pure
Zig in `src/dap.zig`; shell integration lives only in `src/completion_test.zig`.

---

## 2. Ground truth checked in the current tree

The design makes several claims about the existing implementation. All were verified; use these anchors instead of
re-deriving them.

| Design claim                                                                          | Where it is true now                                                     |
| ------------------------------------------------------------------------------------- | ------------------------------------------------------------------------ |
| `generate` builds a local `Base` with `app_meta`, `specs`, `commands`, `View`         | `src/dap.zig:2125-2129`                                                  |
| A command level returns a thin forwarding shell                                       | `src/dap.zig:2759-2772`                                                  |
| `Sub` and `subApp` rebuild a child namespace; `commandNodes` recurses identically     | `src/dap.zig:2814`, `2857`, `2904`                                       |
| `Spec` carries `name/kind/vtype/long/short/optional/alt/alt_branch/help`              | `src/dap.zig:2916-2937`                                                  |
| `CommandEntry` carries `field/view_field/name/rank/Cmd`                               | `src/dap.zig:2954-2960`                                                  |
| Ranks are contiguous pre-order positions                                              | `normalizeRanked` at `src/dap.zig:3745`                                  |
| `App._command_rank` is a public field defaulting to 0                                 | `src/dap.zig:88-95`                                                      |
| Builtin `-h/--help` is injected first in every declaration                            | `BuiltinHelp` at `src/dap.zig:1742`, `withBuiltinHelp` at `1790`         |
| `Spec.short` is stored without a dash; short aliases are whole tokens                 | `specFromField` at `src/dap.zig:3435-3437`, `consumeShortFlag` at `2712` |
| Non-bool flags consume the next wire token                                            | `assignValue` call sites in `assignLongFlag`/`assignShortFlag`           |
| Long and short names are globally unique in the tree                                  | `collectFlagOrigins`/`checkGlobalFlagNames` at `src/dap.zig:3664/3694`   |
| `Enumeration` results expose `EnumView` and `names`; the empty result exposes neither | `src/dap.zig:354-378` vs `295-317`                                       |
| `ArrayList(u8)` output pattern with `errdefer out.deinit(allocator)`                  | `renderCompact` at `src/dap.zig:858-870`                                 |
| OOM sweep style (`FailingAllocator`, probe count, `allocated_bytes == freed_bytes`)   | `src/dap.zig:6517-6541`                                                  |
| Build module/test shape                                                               | `build.zig:7-40`                                                         |
| Root re-exports are explicit                                                          | `src/root.zig:4-29`                                                      |

Current placement anchors (they shift as code is added; re-grep rather than trust numbers):

- Public data types: `Kind` at `src/dap.zig:54`, help renderer types at `64-77`.
- Private help scaffolding: `1114-1500`.
- Private suggest scaffolding: `1815-1999`.
- `generate`: `2001`.
- `Base` helpers: `2125-2359`.
- `Base.usage`: `2329`.
- Command shell alias block: `2759-2772`.
- Test blocks: `3791-7409` (M1 to M18).

---

## 3. Invariants

1. The completion generator is static. It takes no `View`, never parses, never reads the environment, and does no file
   I/O.
2. `app_name` is the only runtime input besides the allocator and the shell.
3. No new dependencies; `std` only.
4. No changes to `Spec`, `CommandEntry`, `normalize`, `parse`, `View`, or the DSL. Completion reads the existing
   comptime tables.
5. Every generated namespace exposes `completion`; only the root rank may call it. A non-root call is a compile error
   from the body, not from the alias.
6. User strings are data. Identifiers come only from `app_name`; quoting is applied everywhere a user string reaches
   shell code.
7. The script is deterministic and ends with exactly one `\n`.
8. Failures allocate nothing on the invalid-name path, and a failed render frees everything.

---

## 4. Internal design

### 4.1 Public surface

Add beside `HelpRendererHighlight` (after `src/dap.zig:77`):

```zig
/// Shell dialect a completion script is generated for.
pub const CompletionShell = enum { bash, zsh, fish };

/// Errors a completion-script render can produce.
pub const CompletionError = std.mem.Allocator.Error || error{InvalidAppName};
```

Add to `src/root.zig` next to the help exports:

```zig
pub const CompletionShell = @import("dap.zig").CompletionShell;
pub const CompletionError = @import("dap.zig").CompletionError;
```

`completion` itself is reached through the generated namespace, like `parse`/`helpText`.

### 4.2 Private table and helpers

Insert before `generate` (after `suggestProbe`, around `src/dap.zig:1999`), with the same file-private visibility as the
help scaffolding:

```zig
const CompletionLevel = struct {
    rank: usize,
    path: String,
    flags: []const Spec,          // ancestors first, then own; builtin once
    arguments: []const Spec,      // own only; reserved
    commands: []const CommandEntry,
};

fn completionLevels(
    comptime NS: type,
    comptime inherited_flags: []const Spec,
) []const CompletionLevel;

fn enumWireNames(comptime T: type) []const String;
```

Copy the design's body for `completionLevels` (design §"Level model"). Keep the `@setEvalBranchQuota(1_000_000)` and the
`Sub(c.Cmd, subApp(NS.app_meta, c))` recursion exactly; it must instantiate the same namespaces `View` and
`commandNodes` already instantiate. `enumWireNames` is structural: non-struct -> empty, missing `EnumView` or `names` ->
empty, otherwise `&T.names`.

Add the runtime scaffolding:

```zig
fn isValidCompletionAppName(name: String) bool;
fn completionIdent(allocator: std.mem.Allocator, app_name: String) std.mem.Allocator.Error![]u8;

const CompletionQuote = enum { posix, fish };
fn appendQuoted(out: *std.ArrayList(u8), allocator: std.mem.Allocator, s: String, quote: CompletionQuote) std.mem.Allocator.Error!void;
fn appendSanitized(out: *std.ArrayList(u8), allocator: std.mem.Allocator, s: String) std.mem.Allocator.Error!void;
fn appendLevelMarker(out: *std.ArrayList(u8), allocator: std.mem.Allocator, level: CompletionLevel) std.mem.Allocator.Error!void;

fn valueFlagSpellings(comptime levels: []const CompletionLevel) []const String;

fn completionScript(
    allocator: std.mem.Allocator,
    comptime NS: type,
    app_name: String,
    shell: CompletionShell,
) CompletionError!String;

fn emitBash(allocator: std.mem.Allocator, comptime levels: []const CompletionLevel, ident: String, app_name: String) std.mem.Allocator.Error!String;
fn emitZsh(allocator: std.mem.Allocator, comptime levels: []const CompletionLevel, ident: String, app_name: String) std.mem.Allocator.Error!String;
fn emitFish(allocator: std.mem.Allocator, comptime levels: []const CompletionLevel, ident: String, app_name: String) std.mem.Allocator.Error!String;
```

Notes:

- `completionIdent` allocates `app_name.len` bytes and maps bytes outside `[A-Za-z0-9_]` to `_`. It is called only after
  validation. The caller frees it with `defer`.
- `valueFlagSpellings` walks all levels, collects `--long` and `-short` for every flag with `s.vtype != bool`, dedupes
  by spelling, and returns them in first-seen order. `bool` is the only non-value type (the help renderer uses the same
  rule at `src/dap.zig:2358`).
- Each emitter starts with `var out: std.ArrayList(u8) = .empty; errdefer out.deinit(allocator);` and returns
  `try out.toOwnedSlice(allocator)`.
- `appendSanitized` maps `\n`, `\r`, `\t` to a space. It is used for level marker paths and descriptions, never for
  candidates.
- `appendQuoted` implements the two quoting modes from the design. For POSIX it rewrites `'` as `'\''`; for fish it
  escapes `\` and `'` with a backslash.
- Numeric output (ranks, counts) goes through `out.print(allocator, ...)`, as in `src/main.zig`; no temporary strings.

### 4.3 Entry point and root-only check

Add beside `helpData`/`helpText`/`usage` in `Base`:

```zig
pub fn completion(
    allocator: std.mem.Allocator,
    app_name: String,
    shell: CompletionShell,
) CompletionError!String {
    comptime {
        if (app._command_rank != 0) {
            @compileError("dap.completion: call it on the root namespace, got '" ++
                app.name ++ "'");
        }
    }
    return completionScript(allocator, @This(), app_name, shell);
}
```

`@This()` is `Base`, not the forwarding shell, which is what `completionLevels` needs. Add
`pub const completion = Base.completion;` to the command shell alias block (`src/dap.zig:2759-2772`). Aliasing does not
analyze the body, so a child call still fails at its call site.

`completionScript` performs, in order:

1. `if (!isValidCompletionAppName(app_name)) return error.InvalidAppName;` (no allocation before this line),
2. `const ident = try completionIdent(allocator, app_name); defer allocator.free(ident);`
3. `const levels = comptime completionLevels(NS, &.{});`
4. `return switch (shell) { .bash => emitBash(...), .zsh => emitZsh(...), .fish => emitFish(...) };`

Validation rule, byte by byte: non-empty, ASCII, no whitespace or control bytes, no `/`, first byte not `-`, every byte
in `A-Za-z0-9._+-`.

### 4.4 Script shape and candidate rules

All three emitters share this contract:

1. Helpers, then a driver, then registration. Bash's registration is the trailing `complete` line; zsh starts with
   `#compdef` and ends with the `funcstack` guard; fish ends with `complete -c`.
2. One `# dap: level <rank> <sanitized App.name>` line immediately before each level's block in the dispatch. No other
   comments are required.
3. Ordinary candidates: iterate `level.flags` in order (long, then short when non-empty), then `level.commands` in
   declaration order. Skip an empty long, empty short, empty command name, and command names starting with `-`.
4. Value positions use `level.flags` plus `enumWireNames(s.vtype)`. `Alt` branches are not pruned. Arguments are not
   completed.
5. Enumeration values appear only for flags whose `vtype` is structurally enumerable; the empty `Enumeration`
   contributes nothing.
6. Exactly one trailing newline.

---

## 5. Milestones

Each milestone ends with `zig fmt --check src build.zig && zig build test`. Do not start the next milestone with a red
tree.

### M0. Public types and re-exports

**Files:** `src/dap.zig`, `src/root.zig`.

- Add `CompletionShell` and `CompletionError` with doc comments.
- Export both from `src/root.zig`.

**Exit:** `zig build test` green; a scratch test can name `@import("dap").CompletionShell`.

### M1. Level model

**Files:** `src/dap.zig`.

- Add `CompletionLevel`, `completionLevels`, `enumWireNames`.
- Do not wire `Base.completion` yet.
- Add M19 tests:
  - level table for a minimal tree (bool flag, enumeration flag, one command, one nested command),
  - larger tree with `Group`, `Alt`, an optional flag, a sibling command, and an argument-bearing leaf,
  - per-level effective flags (ancestor first, builtin exactly once), per-level commands, per-level arguments, pre-order
    ranks,
  - sibling isolation: a child's list contains ancestors and its own flags, no sibling flags,
  - `enumWireNames`: `Enumeration` names in declaration order, empty `Enumeration` empty, scalar/string/custom struct
    empty.

**Exit:** `zig build test` green; M19 level assertions pass.

### M2. Script core, validation, and minimal valid skeletons

**Files:** `src/dap.zig`.

- Add `isValidCompletionAppName`, `completionIdent`, `appendQuoted`, `appendSanitized`, `appendLevelMarker`,
  `valueFlagSpellings`, `completionScript`.
- Add `Base.completion` with the comptime root check, and forward it in the command shell alias block.
- Implement `emitBash`/`emitZsh`/`emitFish` as syntactically valid skeletons: registration, level markers, and an empty
  driver. This keeps every shell callable while the full emitters land one at a time.
- Add M19 tests:
  - `InvalidAppName` for empty, leading `-`, `/`, space, tab/newline, a control byte, non-ASCII; use `FailingAllocator`
    with `fail_index = 0` and assert `allocations == 0` on the invalid path,
  - determinism (two calls, equal bytes), exactly one trailing newline,
  - identifier mapping and registration use `app_name`, not `App.name`,
  - `CompletionShell` dispatch returns the right registration for each shell,
  - the command shell forwards `completion` (`@hasDecl`, root and child),
  - root-only negative case guarded by `if (false)` or commented out.

**Exit:** tests green; `zig build run -- --help` unchanged.

### M3. Bash emitter

**Files:** `src/dap.zig`.

Implement the full bash script:

- `_dap_<ident>_filter` (array loop, no `compgen -W`).
- `_dap_<ident>_value_flag` with `*=*` rejected first, then one pattern per value-flag spelling from
  `valueFlagSpellings`.
- Driver `_dap_<ident>`:
  - `cur`, `prev`, `level=0`, `literal=0`;
  - previous words `COMP_WORDS[1..COMP_CWORD-1]`, lookahead of two for a value flag followed by `=`, one otherwise;
  - `--` sets `literal`; flag-looking tokens (`-` plus length > 1) never match commands; per-level nested `case`
    descends on command names;
  - current-word shape: `cur == '='` (eq form, candidates prefixed `=`), `prev == '='` (bare values, target is after
    `=`), separate value (bare values), no-wordbreak full form (`vform=full`);
  - per-level dispatch with value arms for enum flags and `COMPREPLY=()` for non-enum values, then the ordinary
    candidate list via `_filter`;
  - literal state leaves `COMPREPLY=()` so `-o default` takes over.
- Registration: `complete -o default -F _dap_<ident> <quoted app_name>`.
- Bash 3.2 only: no associative arrays, `mapfile`, or `compopt`.

**Exit:** `bash -n` on a generated script; M19 bash assertions for candidates, enum values, value table, terminator,
quoting.

### M4. zsh emitter

**Files:** `src/dap.zig`.

- `#compdef` first line, driver `_<ident>`, guard at the end.
- `emulate -L zsh` at the driver top, local variables only.
- Scan over `words[2..CURRENT-1]` with the same value-skip lookahead.
- Per-level `cands`/`displays` arrays; `compadd -o nosort -d displays -- "${cands[@]}"`. Empty help makes the display
  equal the candidate.
- Value positions: bare values after a separate flag, full `--long=value` / `-s=value` for inline forms, `=value` when
  the current word is a bare `=`, and `return 1` for non-enum values, the literal state, or no candidates.
- Guard exactly as designed.

**Exit:** `zsh -n`; M19 zsh assertions.

### M5. fish emitter

**Files:** `src/dap.zig`.

- Driver `__dap_<ident>_complete`; `set -l toks (commandline -opc)`, drop `toks[1]`, `set -l cur (commandline -ct)`.
- Index loop with `math` for increments; `string match -qr '^-'` flag test; nested `switch`/`case` for command descent;
  `--` sets literal.
- `__dap_<ident>_value_flag` with `case '*=*'` first, then all value-flag spellings.
- Ordinary candidates printed as `printf '%s\t%s\n' candidate description`, or `printf '%s\n' candidate` when help is
  empty. Skip a candidate containing a tab or newline. Sanitize descriptions.
- Value positions: full `--long=value` for inline `cur`, bare values after a separate value flag, nothing for non-enum
  values and literal state.
- Registration: `complete -c <quoted app_name> -a '(__dap_<ident>_complete)'`; no `-f`.

**Exit:** `fish -n`; M19 fish assertions.

### M6. Full M19 matrix and goldens

**Files:** `src/dap.zig`.

- Complete the candidate-emission, enumeration-value, value-skip, terminator, quoting, description-sanitization, and
  identifier-isolation tests.
- Add the OOM sweep across all three shells: probe `completion`, then loop `fail_index` from 0 through the probe count,
  accept success or `OutOfMemory`, and assert `allocated_bytes == freed_bytes` each time.
- Add full-script goldens for the tiny tree, one per shell. Generate them from the finished emitters only after a manual
  read of each script; goldens lock registration, the zsh guard, the fish registration line, and the skeleton.
- Keep the larger-tree assertions structural, scoped by the `# dap: level` markers, so goldens stay small.

**Exit:** `zig build test` green with the whole M19 block.

### M7. Shell integration step

**Files:** `src/completion_test.zig` (new), `build.zig`.

- The file imports the public module: `const dap = @import("dap");`.
- Build one small declaration (root bool flag, enumeration flag, command with a nested command) with
  `App.name = "dap completion test"` and `app_name = "dap-completion-test"`, generate all three scripts, and write them
  into `std.testing.tmpDir(.{})`.
- Use `std.testing.io` with `std.process.run` (`argv`, `cwd`, stdout/stderr captured, results freed). Treat
  `error.FileNotFound` as "shell missing": print a notice and skip that shell, do not fail.
- Skip the whole file on Windows (`builtin.os.tag == .windows`).
- Checks:
  - syntax: `bash -n`, `zsh -n`, `fish -n`;
  - bash semantics: source the script, set `COMP_WORDS`/`COMP_CWORD`, call `_dap_<ident>`, assert `COMPREPLY` for: root
    flag prefix, child command after a command token, ancestor flag on a child level, enum value after `--color`,
    `COMP_WORDS=(app --color = r)`/`COMP_CWORD=3` (bare `red`), `COMP_WORDS=(app --color =)`/`COMP_CWORD=2` (expect
    `=red`), a non-enum value flag (empty), and the literal state after `--`;
  - fish semantics: `fish --no-config -c 'source <path>; complete -C "app --co"'` plus `"app --color "`,
    `"app --color=r"`, a command token, a value flag, and a `--` line; assert tab-separated candidate/description output
    set-wise (fish sorts);
  - zsh: syntax check plus a sourcing smoke test inside `compinit`
    (`zsh -f -c 'autoload -Uz compinit; compinit -u -D; source <path>; whence -w _<ident>'`); semantic zsh completion
    stays manual;
  - registration: exactly `app_name` is registered, a second `app_name` produces a different identifier and
    registration, and `App.name` is not used for registration.
- `build.zig`: add a `completion-test` step and a test root for `src/completion_test.zig` with
  `addImport("dap", dap_module)`. `test` must not depend on it.

**Exit:** `zig build test` still does not compile the new file; `zig build completion-test` passes with all three shells
installed and skips missing ones with a visible notice.

### M8. Example and documentation

**Files:** `src/main.zig`, `README.md`, `AGENTS.md`, `AGENTS-SDK.md`.

- Add a `completion` command to the example tree, with an `Enumeration` argument for `bash`/`zsh`/`fish`; print the
  script to stdout and return. Add the new case to the `CLI.command` switch. The example root declares a required flag,
  so manual checks use `zig build run -- --required 0 completion bash`.
- `README.md`: add `## Completion` after `## Help` with the API, `app_name` rules, root-only rule, install commands,
  regeneration note, and documented limitations (sanitized identifier collisions, no zsh semantic autotest). Add
  `zig build completion-test` to `## Building and testing`.
- `AGENTS.md`: update the status/test count, layout (new file and step), the public type list, the root-only rule, the
  `app_name` contract, the level model, the two test surfaces, and the M19 block.
- `AGENTS-SDK.md`: add `completion` to the namespace method table and a short consumer section (see §9, decision 2).

**Exit:** manual checks:

```sh
zig build run -- --required 0 completion bash | bash -n
zig build run -- --required 0 completion zsh  | zsh -n
zig build run -- --required 0 completion fish | fish -n
```

### M9. Final verification

- `zig fmt --check src build.zig`
- `zig build test`
- `zig test src/dap.zig`
- `zig build completion-test`
- `zig build run -- --help`
- Count the tests and update the `AGENTS.md` status line with the real number.
- Re-read the design's "Tests" and "Placement and ordering" sections and tick every bullet (the §6/§7 matrices below are
  the checklist).

---

## 6. M19 test matrix (pure Zig, `src/dap.zig`)

| Design bullet      | M19 test(s)                                                                         | Notes                                                                                         |
| ------------------ | ----------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------- |
| Level table        | `level table`, `larger tree levels`                                                 | assert ranks, paths, flags, arguments, commands                                               |
| Sibling isolation  | `sibling isolation`                                                                 | child flags contain no sibling flags                                                          |
| Candidate emission | `bash candidates by level`, `zsh candidates by level`, `fish candidates by level`   | slice between `# dap: level` markers                                                          |
| Enumeration values | `enumeration values by position`, `short enum spelling`, `empty enumeration values` | bare, `=value`, full `--long=value`, `-s=value`                                               |
| Value-skip table   | `value flag table`                                                                  | every non-bool long/short present, bool absent, `*=*` rejected                                |
| Terminator         | `literal state emits nothing`                                                       | assert the literal branch exists and registration keeps file fallback                         |
| Quoting            | `posix quoting`, `fish quoting`, `description sanitization`                         | `'`, `"`, `\`, spaces, `:`; newline becomes space                                             |
| Identifiers        | `identifier sanitization`                                                           | `my-app` -> `_dap_my_app`/`_my_app`/`__dap_my_app_complete`; collision `a-b`/`a_b` documented |
| Determinism        | `determinism`                                                                       | equal bytes, one trailing `\n`                                                                |
| OOM sweep          | `out of memory sweep`                                                               | all three shells, probe + fail-index loop                                                     |
| Invalid name       | `invalid app name`                                                                  | `InvalidAppName`, `allocations == 0`                                                          |
| Goldens            | `bash golden`, `zsh golden`, `fish golden`                                          | tiny tree only                                                                                |
| Root-only          | `completion is root-only`                                                           | `if (false)` or commented-out child call                                                      |

Test declarations: `M19Def` (minimal) and `M19BigDef` (groups, Alt, optional, sibling commands, argument leaf). Reuse
`M8`'s `Enumeration` for the enum flag, or declare a local one. Prefer direct calls to the private
`completionLevels`/emitters over re-parsing scripts where possible.

---

## 7. Integration test matrix (`src/completion_test.zig`)

| Case                        | bash                    | fish               | zsh                            |
| --------------------------- | ----------------------- | ------------------ | ------------------------------ |
| Syntax                      | `bash -n`               | `fish -n`          | `zsh -n`                       |
| Root flag prefix            | `--verbose`             | `complete -C`      | manual                         |
| Child command               | `run` after `run` token | `complete -C`      | manual                         |
| Ancestor flag after handoff | `--verbose` on child    | `complete -C`      | manual                         |
| Enum separate value         | bare `red`              | bare `red`         | manual                         |
| Enum eq with text           | bare `red`              | full `--color=red` | manual                         |
| Enum eq empty               | `=red`                  | full `--color=red` | manual                         |
| Non-enum value              | empty `COMPREPLY`       | no candidates      | manual                         |
| Literal after `--`          | empty `COMPREPLY`       | no candidates      | manual                         |
| Registration                | script text             | script text        | script text + `compinit` smoke |

Integration assertions are set-based for fish because `complete -C` sorts. A shell that is absent is skipped with a
visible notice; the step is opt-in.

---

## 8. Emitter notes

### Bash

- Driver order: filter, value-flag helper, driver, registration.
- Compute `cur` and `prev` once. Guard `COMP_CWORD >= 1` before indexing `prev`, and `COMP_CWORD >= 2` before
  `COMP_WORDS[COMP_CWORD-2]`.
- Scan with `end=$((COMP_CWORD - 1))`; a value flag at `i` skips two words when `COMP_WORDS[i+1]` is `=`, otherwise one.
  Skipping past `end` simply ends the loop.
- A token that starts with `-` and has length > 1 is a flag, never a command.
- `vform` is `bare` by default, `eq` when `cur == '='`, `full` for the no-wordbreak `--long=value` current word. Value
  arms are per spelling, so `-c=red` and `--color=red` are both available.
- Non-enum value positions set `COMPREPLY=()` and return; `-o default` keeps file completion. Do not use `compopt`.
- No descriptions.

### zsh

- `#compdef` uses the raw validated `app_name`; the charset makes quoting redundant in a directive that is not shell
  code. Quote `compdef`'s arguments normally.
- `emulate -L zsh`; `local` everything except the read-only completion parameters.
- `end=$(( CURRENT - 1 ))`; scan indexes 2 through `end`.
- Large/small candidates: `cands` and `displays` arrays; display is `candidate  help`, or the candidate alone when help
  is empty; sanitize help.
- Inline `--long=value`: emit full candidates. If the target zsh moves the `--long=` part into `IPREFIX`, the guarded
  fallback runs `compset -P '*='` and adds bare values. Implement the `PREFIX` path first and add the fallback only
  after observing it; both must leave a syntactically valid script.
- Empty value position and literal state return non-zero without `compadd`.

### fish

- `commandline -opc` excludes the current token; drop `toks[1]`. `-ct` is the current token, including a whole
  `--long=value` form.
- Use `math` for the index increment; fish has no `(( ))`.
- Tab is the separator: skip a candidate containing a tab or newline, and sanitize descriptions. Empty help prints the
  candidate alone.
- Inline current word prints full `--long=value` candidates; a separate value flag prints bare values; everything else
  in a value position prints nothing.
- Registration without `-f` keeps file completion for arguments and non-enum values.

---

## 9. Decisions taken (not fixed by the design)

1. **`#compdef` spelling.** Emit the raw validated `app_name` on the `#compdef` line, because the `app_name` charset
   guarantees no whitespace or metacharacters and the directive is parsed by `compinit`, not by the shell. Use the
   quoting helpers for `compdef`, bash `complete`, and fish `complete -c`. Verify with the zsh smoke test; if `compinit`
   disagrees, quote there too.
2. **`AGENTS-SDK.md`.** The design's placement list names `AGENTS.md` only. Update `AGENTS-SDK.md` as well, because
   every prior public-surface change updated the consumer reference. Keep it short: method table row plus a completion
   section.
3. **Example invocation.** The example root declares a required flag, so the manual `completion` command needs
   `--required 0`. Document this in the README manual-check snippet rather than weakening the example.
4. **zsh inline values.** Implement the `PREFIX` full-candidate path first; add the `IPREFIX`/`compset -P '*='` fallback
   behind an observed condition. Semantic zsh completion is manual, per the design.
5. **The `--` token itself.** `literal` becomes true only when `--` is among the already-consumed words. Typing `--` as
   the current word still offers flags (it is not yet a completed terminator); the next word gets no library candidates.
   This matches the parser, which treats `--` as the terminator and then consumes the rest as positionals.
6. **fish index arithmetic.** "Arithmetic-free" means no `(( ))`; `math` is the idiomatic fish increment and is the only
   arithmetic used.
7. **Test naming.** Keep the `M19:` prefix, the `completion-test` step name, and the `src/completion_test.zig` file name
   exactly as designed.

---

## 10. Risks and verification

| Risk                                         | Verify with                                                                         |
| -------------------------------------------- | ----------------------------------------------------------------------------------- |
| bash `=` wordbreak and lookahead off-by-one  | integration cases `--color=red`, `--color=`, separate value; `bash -n`              |
| bash 3.2 compatibility                       | review for `mapfile`, associative arrays, `compopt`; run on macOS bash if available |
| zsh `compadd -d` display semantics           | interactive zsh check; smoke test only asserts definition                           |
| zsh `PREFIX` vs `IPREFIX` for `--long=value` | manual `zpty`/interactive check; guarded fallback                                   |
| zsh guard in autoload and sourced modes      | `source <(script)` and autoload file smoke tests                                    |
| fish `-opc`/`-ct` at the cursor              | `complete -C` cases for `--color`, `--color=`, `--color=r`, `--`                    |
| candidate names with spaces/colons           | M19 quoting tests plus `bash -n`/`zsh -n` on a pathological declaration             |
| fish tab/newline protocol                    | skip rule in the fish emitter; M19 assertion                                        |
| identifier collisions (`a-b`/`a_b`)          | M19 assertion documenting the limitation                                            |
| `#compdef` punctuation                       | integration uses `dap-completion-test`; smoke test                                  |
| large tree compile time/script size          | M19 larger tree; no laziness planned                                                |

If a shell is absent during implementation, record the check as manual in the final report rather than weakening the
integration test.

---

## 11. Definition of done

- [ ] `CompletionShell` and `CompletionError` are public and re-exported.
- [ ] Every generated namespace exposes `completion`; a child call is a compile error; the alias itself does not analyze
      the body.
- [ ] `app_name` validation allocates nothing and rejects every invalid form.
- [ ] Identifier mapping, quoting, and description sanitization match the design tables.
- [ ] The level table is ancestor-first, builtin help appears once, sibling flags never leak, commands/arguments are
      own-level only.
- [ ] All three emitters pass syntax checks and the M19 assertions.
- [ ] Goldens lock registration, guards, and skeleton; the larger tree is asserted structurally.
- [ ] OOM sweep is green for all shells.
- [ ] `zig build test` never compiles or runs `src/completion_test.zig`.
- [ ] `zig build completion-test` passes or visibly skips missing shells.
- [ ] README, AGENTS.md, and AGENTS-SDK.md describe the API, the root-only rule, installation, and limitations.
- [ ] The example prints all three scripts manually.
- [ ] The real test count is recorded in `AGENTS.md`.

---

## 12. Suggested commit sequence

1. `feat: add the completion shell types and level table`
2. `feat: generate bash completion scripts`
3. `feat: generate zsh completion scripts`
4. `feat: generate fish completion scripts`
5. `test: cover completion tables, quoting, and failures`
6. `test: exercise generated scripts in real shells`
7. `docs: document completion generation`

Keep the parser/DSL/View untouched in every commit, and keep `zig build test` green at each boundary.
