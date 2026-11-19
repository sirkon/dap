# Completion scripts

## Goal

Add a completion-script generator to `dap`. Calling it on the generated
namespace produces a complete, installable completion script for bash, zsh or
fish for the whole command tree declared by the type.

Completion is a pure function of the comptime declaration: the normalized
`specs` and `commands` tables plus `app_meta`. A `View` carries runtime values
only, and no runtime value can change which flags or commands exist, so the
generator takes no `View` and never parses.

The design is **static**: the generated script embeds the declaration and scans
the words itself. There is no environment handshake, no callback into the
binary, no second API and no change to a user's `main`.

## Public API

```zig
/// Shell dialect a completion script is generated for.
pub const CompletionShell = enum { bash, zsh, fish };

/// Errors a completion-script render can produce.
pub const CompletionError = std.mem.Allocator.Error || error{InvalidAppName};
```

In the generated namespace, beside `helpData`, `helpText` and `usage`:

````zig
/// Render a completion script for this declaration.
///
/// `app_name` is the command name the script registers (a bare binary name,
/// not the declaration's usage path). The script is a snapshot of the
/// declaration; regenerate it when flags or commands change. The caller owns
/// the returned string and releases it with the same allocator.
///
/// ```
/// var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
/// defer arena.deinit();
/// const script = try CLI.completion(arena.allocator(), "app", .zsh);
/// ```
pub fn completion(
    allocator: std.mem.Allocator,
    app_name: String,
    shell: CompletionShell,
) CompletionError!String
````

- `String` is the project alias for `[]const u8`.
- The argument order is allocator, app name, shell. `app_name` is required;
  Zig has no default arguments and a second overload would only complicate the
  surface.
- The result is one complete script terminated by exactly one `\n`, so
  redirecting it to a file or piping it is clean.
- The caller owns the result through `allocator`; with an arena the arena
  releases it. There is no hidden cache and no library free function.
- Output is deterministic: the same declaration, `app_name` and shell produce
  identical bytes, with no timestamps, environment probes or locale.
- `src/root.zig` re-exports `CompletionShell` and `CompletionError`. The
  function itself is reached through the generated namespace, like `parse` and
  `helpText`.

### `app_name`

`app_name` is the registered command name, not `App.name`. `App.name` is the
usage path (`app svc build` at a deep level, and command names may contain
spaces); `app_name` is what appears in `complete -c`, `#compdef` and `compdef`.
The parameter exists precisely because the declaration cannot know the
installed invocation name (aliases, symlinks, renamed binaries). There is no
cross-check between the two: passing a name different from the installed binary
registers that other name, which is the intended way to install under an alias.

`app_name` is validated at runtime before any allocation. A name is valid when
it is:

- non-empty;
- ASCII;
- free of whitespace and control bytes;
- free of `/`;
- not starting with `-`;
- composed only of `A-Za-z0-9._+-`.

A violation returns `error.InvalidAppName` with no allocation performed. There
is no empty-name fallback to `App.name`, because that may be a multi-word usage
path.

Registration always uses `app_name` verbatim, quoted by the shell's quoting
helper. Shell identifiers are derived from it by replacing every byte outside
`[A-Za-z0-9_]` with `_`:

| Shell | Identifier pattern        | `my-app` example        |
| ----- | ------------------------- | ----------------------- |
| bash  | `_dap_<ident>`            | `_dap_my_app`           |
| zsh   | `_<ident>`                | `_my_app`               |
| fish  | `__dap_<ident>_complete`  | `__dap_my_app_complete` |

Identifiers are derived only from the sanitized `app_name`, never from command
names, flag names, help text or `App.name`, so user strings cannot break the
script. Sanitization is not injective (`a-b` and `a_b` both become `a_b`); two
dap CLIs whose names sanitize alike would collide in one bash or fish session.
That is a documented limitation, not a hash-suffixed identifier.

### Root-only

The script is tied to a binary's argv, not to a parsed value. A subcommand level
cannot reconstruct its ancestors: `app_meta.name` is a space-joined usage path,
command names may themselves contain spaces, and there is no parent pointer.
Since parsing accepts ancestor flags at every level, a subtree-only script would
advertise an incomplete flag set.

`completion` therefore exists on every generated namespace but compile-errors on
a call from a non-root level:

```zig
comptime {
    if (app._command_rank != 0) {
        @compileError("dap.completion: call it on the root namespace, got '" ++
            app.name ++ "'");
    }
}
```

The check runs when the function is analyzed. Aliasing it in the command
accessor shell (`pub const completion = Base.completion;`) does not analyze the
body, so forwarding is safe and the error appears only at a call site. A
commandless child level returns a plain `Base` with rank ≠ 0, carries the same
decl and fails the same way when called. The project has no compile-fail
harness, so the negative case stays a commented-out or `if (false)`-guarded
declaration in the tests, as with the other comptime checks.

`App._command_rank` is documented-internal but is a public struct field; a
user-supplied value can defeat the check. The compile message is the only
defense.

## What the declaration already provides

- `generate` builds a local `Base` with `pub const app_meta = app`,
  `specs = all_specs`, `commands = cmd_entries` and `View`. A level that
  declares subcommands returns a forwarding shell re-exporting all three.
- `specs` is the flat normalized list. The injected `-h, --help` is first in
  every declaration, `Group` and `Alt` members are already flattened, and each
  entry carries `kind`, `name`, `long`, `short`, `vtype`, `optional`, `alt`,
  `alt_branch` and `help`. For a flag, `long` is the wire name.
- `commands` holds one `CommandEntry` per child with `field`, `view_field`, wire
  `name`, pre-order `rank` and the `Command(...)` type `Cmd`.
  `c.Cmd.cmd_meta.help` is the child's description.
- `Sub(c.Cmd, subApp(app, c))` rebuilds a child namespace, and `commandNodes`
  already recurses with exactly that expression, so the completion table uses
  the identical namespace instantiation.
- Parsing retries an unknown flag against every ancestor, so a deep level
  accepts ancestor flags. Flag long names and short aliases are globally unique
  across the whole tree (`collectFlagOrigins` / `checkGlobalFlagNames`), which
  makes the generated value-skip table exact.
- Short aliases are whole tokens: `-abc` is the alias `abc`, not `-a -b -c`.
  Both long and short forms accept `=value`. Boolean flags never consume the
  next token; every other value type does (the `s.vtype != bool` rule help
  uses).
- A `--` token makes the rest of the wire literal positionals and suppresses
  command handoff.
- An `Enumeration(...)` result exposes `EnumView` and `names` (the wire-name
  list, in declaration order). The empty `Enumeration` result has no `names`.

## Level model

Completion needs one thing `commandNodes` does not keep: ancestry. A level's
effective flags are its own plus every ancestor's, in ancestor-first order.
Commands and arguments belong to the current level only; the parser rejects
mixing commands with positional arguments, so an argument-bearing level is a
leaf.

A private comptime table drives all three emitters:

```zig
const CompletionLevel = struct {
    rank: usize,                      // App._command_rank, unique in the tree
    path: String,                     // App.name, for per-level script comments
    flags: []const Spec,              // ancestors first, then own; builtin once
    arguments: []const Spec,          // own only (reserved; no value completion)
    commands: []const CommandEntry,   // own only
};

fn completionLevels(
    comptime NS: type,
    comptime inherited_flags: []const Spec,
) []const CompletionLevel {
    comptime {
        @setEvalBranchQuota(1_000_000);

        var flags = inherited_flags;
        for (NS.specs) |s| {
            if (s.kind != .flag) continue;
            var duplicate = false;
            for (flags) |prev| {
                if (std.mem.eql(u8, prev.long, s.long)) {
                    duplicate = true;
                    break;
                }
            }
            if (!duplicate) flags = flags ++ &[_]Spec{s};
        }

        var arguments: []const Spec = &.{};
        for (NS.specs) |s| {
            if (s.kind == .argument) arguments = arguments ++ &[_]Spec{s};
        }

        var levels: []const CompletionLevel = &[_]CompletionLevel{.{
            .rank = NS.app_meta._command_rank,
            .path = NS.app_meta.name,
            .flags = flags,
            .arguments = arguments,
            .commands = NS.commands,
        }};
        for (NS.commands) |c| {
            levels = levels ++ completionLevels(
                Sub(c.Cmd, subApp(NS.app_meta, c)),
                flags,
            );
        }
        return levels;
    }
}
```

The root call is `comptime completionLevels(Base, &.{})`. The injected builtin
help is the only intentional duplicate across levels; deduplicating by `long`
keeps exactly one `-h, --help` per effective set, at the root's position.
Global uniqueness makes the check exact.

The table is pre-order, root first, matching `commandNodes`. The emitters use
`inline for` over `levels`, `level.flags` and `level.commands`, so `s.vtype`
stays comptime-readable for enumeration detection and candidate lists are
materialized at compile time.

Enumeration detection is structural and guarded against non-struct value types:

```zig
fn enumWireNames(comptime T: type) []const String {
    if (@typeInfo(T) != .@"struct") return &.{};
    if (!@hasDecl(T, "EnumView") or !@hasDecl(T, "names")) return &.{};
    return &T.names;
}
```

`T.names` is an array, so Zig 0.17 needs the address-of operator to coerce it to
`[]const String`; the result is comptime-known and the emitters consume it with
`inline for`. `Spec.vtype` is a pointer type for `[]const u8`, a scalar for
integers and floats, and a struct for a custom type. A custom type that happens
to declare both `EnumView` and `names` is treated as enumerable, the same
structural convention `dap_kind` already uses.

## Context resolution

All three emitters implement one normative scan; each shell's code is a
translation of it.

Input is the words before the cursor, with `argv[0]` and the current (possibly
empty) word excluded.

1. Start at level rank 0, `literal = false`.
2. For each previous word:
   - if `literal`, ignore it;
   - if the word is exactly `--`, set `literal = true`;
   - if the word has the form `--long=value` or `-s=value`, it is a flag with an
     inline value, so never skip the next word;
   - if the word is a flag whose value type is not `bool` (and not an inline
     form), skip its value: the next word, or, in a shell that splits `=` into
     its own word, the `=` and the word after it;
   - if the word starts with `-` and has length greater than 1, it is a flag
     (known or unknown), so it cannot be a command;
   - otherwise match it against the current level's command names; on an exact
     match, descend to that command's level.
3. Resolve the current word against the final level.

Unknown flags are treated as flags, not commands: the parser would reject them,
but completion does not stop at an invalid word. A bare token that matches no
command at the current level leaves the level unchanged.

Value skipping is not cosmetic. In `app --file run`, `run` is `--file`'s value,
not a subcommand; a scanner that ignored this would offer the `run` level. The
parser consumes the next argument for every non-boolean flag.

The value-flag membership table may be global (every value-taking long and short
in the tree) because long and short names are globally unique. Candidate tables
stay per-level, because sibling flags are not valid after a handoff.

After `--`, the parser treats the rest as literal positionals and suppresses
handoff. The scanner sets `literal`, step 3 emits no library candidates, and the
shell's default file completion remains.

### Shell word shapes

The scan assumes real argv words, so each shell normalizes its input to that
shape first.

| Shell | Previous words                     | Current word             | `=` handling |
| ----- | ---------------------------------- | ------------------------ | ------------ |
| bash  | `COMP_WORDS[1 .. COMP_CWORD-1]`    | `COMP_WORDS[COMP_CWORD]` | `=` is in `COMP_WORDBREAKS`, so `--color=red` arrives as `--color`, `=`, `red`. The scan does not build a new array; it looks ahead: a value flag followed by `=` skips two words, otherwise one. |
| zsh   | `words[2 .. CURRENT-1]`            | `PREFIX`                 | `words` normally keeps `--color=red` whole; if a bare `=` word appears, join it with its neighbours or apply the same lookahead. |
| fish  | `commandline -opc` minus `toks[1]` | `commandline -ct`        | `-opc` returns shell words, so `--color=red` is one token. |

The bash wordbreak has a second consequence, for the current word:

- `--color=r` with the cursor after `r`: `COMP_WORDS` ends `--color`, `=`, `r`,
  so `$prev` is `=` and the flag is `${COMP_WORDS[COMP_CWORD-2]}`. `COMPREPLY`
  replaces only `r`, so candidates are bare values (`red`).
- `--color=` with the cursor right after `=`: the `=` itself is the current
  word (`$cur == '='`, `$prev == '--color'`). The replacement target is `=`, so
  candidates are `=red`.
- A separated value (`--color r`): `$prev` is the flag and candidates are bare.
- With `=` removed from `COMP_WORDBREAKS`, `$cur` starts with `--color=` and
  full `--color=red` candidates are correct.

zsh and fish keep the whole token, so their eq-value candidates are full
`--long=value` / `-s=value` spellings. zsh's `compadd` matches candidates
against the completion prefix; when the context treats the whole word as the
prefix (the normal case), full candidates replace it correctly. If a zsh version
moves the `--color=` part into `IPREFIX`, the emitter applies
`compset -P '*='` and adds bare values instead. fish filters printed candidates
against the current token and replaces it.

### Current-word positions

| Position                          | bash | zsh | fish |
| --------------------------------- | ---- | --- | ---- |
| Ordinary word                     | flags + commands | flags + commands | flags + commands |
| After a value-taking flag, no `=` | bare enumeration values, else nothing | same | same |
| `--long=` / `-s=`                 | `=value` candidates when `cur` is `=`; bare values when `prev` is `=`; full `--long=value` without a wordbreak | full `--long=value` | full `--long=value` |
| Non-enum value position           | nothing (file fallback) | nothing, return non-zero | nothing (file fallback) |
| After `--`                        | nothing (file fallback) | nothing, return non-zero | nothing (file fallback) |

"Nothing" means the generator adds no candidates; the shell's own file
completion is left in place. bash registers with `-o default`, fish omits `-f`,
and zsh returns non-zero with no matches so the default completer can take over.

## Candidates

At the resolved level, for an ordinary current word, emit:

- every effective flag, in effective order (ancestors first, then own; the
  builtin help at the root's position), as `--long` and, when present,
  `-short` immediately after it;
- every command of the level as `c.name`, in declaration order.

Rules:

- Enumeration values are emitted bare after a value-taking flag
  (`app --color r` → `red`) and as full `--color=red` / `-c=red` candidates in
  eq positions for zsh and fish (and for bash's no-wordbreak fallback). They
  appear in `names` order, which is declaration order.
- Boolean flags never enter a value position, even though `--flag=true` is
  accepted.
- `Alt` branches are not pruned after one activates. The parser reports the
  conflict; completion keeps offering both.
- Positional-argument values are not completed. Shell file completion is the
  default at leaf levels.
- Empty long names, empty short aliases, empty command names and command names
  starting with `-` are skipped (the parser cannot reach a dash-leading command,
  because flag matching runs first).
- Candidate spellings are verbatim wire names: no case folding, no dash removal,
  no normalization.
- Enumeration values have no descriptions: the current `Enumeration` result
  discards each branch's `Enum.help`.

## Script structure and quoting

Every generated script has the same shape:

1. A registration header: bash's trailing `complete`, zsh's `#compdef` plus the
   `funcstack` guard, fish's `complete -c`.
2. One driver function containing the scan and a per-level dispatcher.
3. A `# dap: level <rank> <path>` comment before each level's block, where
   `<path>` is `App.name` with newlines, carriage returns and tabs replaced by
   spaces. These comments make the script readable and let tests assert
   per-level content by splitting on the markers; they never carry shell
   syntax.
4. Exactly one trailing newline.

All user strings are data, never shell syntax:

- POSIX shells (bash and zsh) quote a literal by wrapping it in `'...'` and
  rewriting `'` as `'\''`.
- fish quotes by wrapping in `'...'` and escaping `\` and `'` with a backslash.
- Descriptions are sanitized before quoting: `\n`, `\r` and `\t` become a
  space.
- Function and variable identifiers come only from the sanitized `app_name`.
- fish uses tab as the candidate/description separator, so a candidate
  containing a tab or newline is skipped there. A newline in a candidate is not
  representable in fish's line protocol; bash and zsh can quote it, but such
  names are pathological and documented as a limitation.
- zsh descriptions use a parallel `displays` array and `compadd -d`, so a `:` or
  a space in a name or help string needs no `_describe` escaping. Spacing is
  baked into each display string, and `-V '' -l` lists one per line.

Descriptions come from `Spec.help` for flags and `cmd_meta.help` for commands.
`i18n` references stay inert, matching the compact help renderer; completion
does not invent a translation path. bash has no description UI and emits words
only.

## Emitters

One emitter per shell. Each is a runtime function writing into one
`std.ArrayList(u8)` with `errdefer out.deinit(allocator)`, returning
`try out.toOwnedSlice(allocator)`.

### bash

Target bash 3.2+ (the macOS default): indexed arrays, `[[ ]]`, `local`,
arithmetic loops; no associative arrays, `mapfile` or `compopt`.

- Driver `_dap_<ident>` and filter helper `_dap_<ident>_filter`, which loops
  over its arguments and appends prefix matches to `COMPREPLY`. An array loop
  is used instead of `compgen -W`, because `-W` word-splits arguments and would
  break command names containing spaces:

  ```bash
  _dap_my_app_filter() {
      local cur=$1; shift
      COMPREPLY=()
      local c
      for c in "$@"; do
          [[ $c == "$cur"* ]] && COMPREPLY+=("$c")
      done
  }
  ```

- Value-flag membership helper `_dap_<ident>_value_flag` with one literal
  pattern per value-taking long/short in the whole tree, and a first branch that
  returns false for any token containing `=`.
- Registration: `complete -o default -F _dap_<ident> <app_name>`, with
  `<app_name>` quoted. `-o default` keeps filename completion wherever the
  generator emits nothing.
- The scan implements the lookahead described above. Command matching is a
  nested `case` per level:

  ```bash
  case "$level" in
  0)
      case "$tok" in
      'run') level=1 ;;
      'build') level=4 ;;
      esac
      ;;
  1)
      case "$tok" in
      'deep') level=2 ;;
      esac
      ;;
  esac
  ```

- After the scan, one `case "$level"` dispatches the current word. Each branch
  starts with the `# dap: level ...` comment, then the value-position arms and
  the ordinary candidate list. Candidates are passed inline to the filter, which
  avoids deriving array names from flag or command text:

  ```bash
  _dap_my_app_filter "$cur" '--help' '-h' '--color' '-c' '--file' '-f' 'run'
  ```

- The wordbreak eq position has three shapes, handled once before the per-level
  dispatch:
  - `cur` is `=` (the user just typed `--color=`): the replacement target is
    the `=` word itself, so enumeration candidates are `=red`, `=green`; a
    non-enum flag leaves `COMPREPLY` empty.
  - `prev` is `=` (the value has at least one character, as in `--color=r`):
    the flag is `${COMP_WORDS[COMP_CWORD-2]}` and candidates are bare values
    (`red`), replacing only the text after `=`.
  - `=` is not a wordbreak: `cur` starts with `--long=` and candidates are full
    `--long=value` spellings.

  ```bash
  local vflag= eq=
  if [[ $cur == '=' ]] && _dap_my_app_value_flag "$prev"; then
      vflag=$prev; eq='='
  elif [[ $prev == '=' ]] && (( COMP_CWORD >= 2 )); then
      vflag=${COMP_WORDS[COMP_CWORD-2]}
  elif _dap_my_app_value_flag "$prev"; then
      vflag=$prev
  elif [[ $cur == *=* && $cur == -* ]]; then
      vflag=${cur%%=*}
  fi
  ```

  The per-level arms compare `$vflag`; when `$eq` is `=`, emitted values are
  prefixed with `=`; the `prev == '='` and separate-value positions use bare
  values; the no-wordbreak prefix form uses full `--long=value` candidates.
  Non-enum flags set `COMPREPLY=()` and return, which falls back to files under
  `-o default`.
- Short aliases are matched whole; there is no cluster expansion.
- Descriptions are not emitted.

### zsh

Target zsh 5.x. The output works as an autoload file and when sourced from a
process substitution.

- First line `#compdef <app_name>`.
- Driver `_<ident>`. When the sanitized identifier differs from `app_name`
  (for example `my-app` → `_my_app`), the autoload file is named after the
  function and the `#compdef` line carries the real command name, which is what
  `compinit` associates.
- Local variables only. The scan uses `words` and `CURRENT`, with the same
  value-flag membership case and a defensive join for a bare `=` word.
- Per-level candidate and display arrays:

  ```zsh
  # dap: level 0 myapp
  cands=('--help' '-h' '--color' '-c' 'run')
  displays=('--help   -- Show help.' '-h       -- Show help.' '--color  -- Color.' '-c       -- Color.' 'run      -- Run it.')
  ```

  Spellings are padded to the widest candidate in the array and help is
  prefixed with `  -- `; empty help falls back to the candidate text, and a
  display array with no help at all (enumeration values) stays unaligned.
- `compadd -V '' -l -d displays -- "${cands[@]}"` for description-bearing
  arrays, so zsh lists one candidate per line in declaration order (the empty
  unsorted group keeps `-o nosort` semantics, which `-l` alone overrides).
  Arrays with no help use `compadd -o nosort -d displays`. With the whole word
  as `PREFIX`, full `--color=red` candidates filter and insert correctly. If the
  target zsh moves `--color=` into `IPREFIX`, `compset -P '*='` is applied first
  and bare values are added; both paths are equivalent and the exact one is
  verified during implementation.
- A value position with no candidates returns non-zero without calling
  `compadd`, letting the default completer handle files.
- The standard guard, which also makes `source <(app completion zsh)` work:

  ```zsh
  if [[ $funcstack[1] == '_my_app' ]]; then
      _my_app "$@"
  else
      compdef _my_app myapp
  fi
  ```

### fish

Target fish 3.x.

- Driver `__dap_<ident>_complete`.
- `set -l toks (commandline -opc)`, drop `toks[1]` (the binary), then
  `set -l cur (commandline -ct)`. `-opc` excludes the current token; `-ct` is
  needed for the eq form and the `--`/value-position tests. Observed on fish
  4.2.1: `app --color r` yields `-opc = app --color` and `-ct = r`;
  `app --color=r` yields `-opc = app` and `-ct = --color=r` (the eq flag is read
  from `cur`, not from the previous words); `app --color ` yields an empty
  `-ct`. `complete -C` prints `candidate<TAB>description` (a plain candidate
  when help is empty) and sorts the output, so integration assertions are
  set-based, not order-based.
- The scan uses `string match -qr '^-' -- $tok` for the flag test,
  `switch`/`case` for per-level command matching, and an arithmetic-free index
  loop.
- The value-flag helper uses `switch $argv[1]` with `case *=*` first (unquoted
  so it stays a glob), then one case with all value-flag spellings.
- Current-word dispatch prints with `printf`:

  ```fish
  # dap: level 0 myapp
  printf '%s\t%s\n' '--help' 'Show context-sensitive help.'
  printf '%s\t%s\n' '-h' 'Show context-sensitive help.'
  printf '%s\t%s\n' 'run' 'Run it.'
  ```

  Eq positions print full `--color=red` candidates; separate value positions
  print bare values; non-enum value positions and the literal state print
  nothing.
- Registration: `complete -c <app_name> -a '(__dap_<ident>_complete)'`. No
  `-f`: file completion stays available for arguments and non-enum value
  positions.

## Installation

The library only returns the script; the user wires the printing command in
their own `main` (for example, a normal `completion` subcommand). With the
generated script saved:

```sh
app completion bash > /etc/bash_completion.d/app
app completion zsh  > "${fpath[1]}/_app"
app completion fish > ~/.config/fish/completions/app.fish
```

The zsh file name must match the autoload function (`_<ident>`); the `#compdef`
line inside carries `app_name`. For a name whose sanitized identifier differs,
the install command names the sanitized file (`_my_app` for `my-app`). For bash,
the trailing `complete` line is enough; for fish, dropping the file in the
completions directory is enough. If the binary is installed under an alias,
generate a second script with that alias as `app_name`: one script registers
exactly one name. zsh is naturally namespaced by the function name; bash and fish
names are namespaced by the sanitized identifier.

## Failure, size, determinism

- Failures are `OutOfMemory` and, on invalid input, `InvalidAppName`.
  Validation runs before any allocation. The identifier buffer is freed with
  `defer`; the script buffer has `errdefer out.deinit(allocator)`, so a failed
  call leaks nothing and never returns a partial script.
- There is no caching. Each call rebuilds the script; with an arena, repeated
  calls accumulate.
- Size is linear in the tree. Effective flag lists duplicate ancestors in each
  descendant's block, which is intentional: the alternative is runtime ancestor
  lookups in shell code, which is harder to keep correct.
- Nothing runs unless `completion` is called: no `View`, no parse, no
  environment, no file I/O, no locale or translated text. `app_name` is the only
  runtime input besides the allocator and shell.

## Placement and ordering

Following the file's existing order in `src/dap.zig`:

1. `CompletionShell` and `CompletionError` go with the public data types near
   `Kind` and the help renderer types.
2. Private scaffolding goes before `generate`, beside the help scaffolding:
   `CompletionLevel`, `completionLevels`, `enumWireNames`, `completionScript`
   and the three emitters, the identifier/validation helpers, the POSIX/fish
   quoting helpers, the description sanitizer, and the comment emitter.
3. `Base.completion` goes beside `helpData`, `helpText` and `usage`.
4. The command accessor shell forwards `completion` in its alias block.
5. `src/root.zig` re-exports `CompletionShell` and `CompletionError`.
6. `build.zig` gains a `completion-test` step and a test root for the dedicated
   file. `test` does not depend on it.
7. `README.md` gains a `## Completion` section after `## Help` with the API and
   installation commands; `## Building and testing` gains
   `zig build completion-test`.
8. `AGENTS.md` records the new public types, the root-only rule, the `app_name`
   contract, the level model, the two test surfaces and the M19 block.
9. `src/main.zig` gains a small `completion` command in the example tree so the
   scripts can be checked manually. That is an example change, not a library
   feature.
10. There are no DSL or declaration syntax changes, no `View` layout changes, no
    parser changes and no normalization changes.

## Tests

Two surfaces, with a hard split.

### M19: pure Zig, in `src/dap.zig`, under `zig build test`

`std.testing.allocator`; no shell is ever executed. The tests may call the
private `completionLevels`, `enumWireNames` and emitters directly.

- **Level table.** Direct assertions on `completionLevels` for a minimal tree
  (one bool flag, one enumeration flag, one command, one nested command) and a
  larger tree with `Group`, `Alt`, optional flags and an argument-bearing leaf:
  per-level effective flags (ancestor first, builtin exactly once), per-level
  commands, per-level arguments, pre-order ranks.
- **Sibling isolation.** A child's effective flag list contains ancestors and
  its own flags and no sibling flags.
- **Candidate emission.** Per-shell substring assertions scoped by the
  `# dap: level` markers: root flags and commands; child flags plus its own
  commands; the builtin help exactly once per level; long and short spellings
  adjacent.
- **Enumeration values.** Bare after `--color`; full `--color=red` in zsh/fish
  eq positions; bare `red` in bash's wordbreak eq position; full `-c=red` for a
  short alias; absent for non-enum value flags; absent for the empty
  `Enumeration`.
- **Value-skip table.** Every non-bool flag long/short is in the membership
  table; bool flags are not; inline `=` forms are not skip forms.
- **Terminator.** No library candidates after `--`; the shell default stays in
  place.
- **Quoting.** Help and command names containing `'`, `"`, `\`, spaces and `:`
  produce the right per-shell escaping; identifiers contain no user text; a
  newline in help becomes a space.
- **Determinism.** Two calls with the same declaration, `app_name` and shell
  produce identical bytes.
- **OOM sweep.** `std.testing.FailingAllocator` in the style of the existing
  help OOM test: probe the total allocation count, then for every `fail_index`
  assert `OutOfMemory` and `allocated_bytes == freed_bytes`.
- **Invalid name.** `expectError(error.InvalidAppName, ...)` for empty, leading
  `-`, `/`, whitespace and a control byte, with no allocations on that path.
- **Goldens.** Full scripts for a tiny tree, one per shell, locking
  registration, the zsh guard, the fish registration line and the overall
  skeleton. The larger tree is asserted structurally so the goldens do not
  become brittle.
- **Root-only.** A commented-out or `if (false)`-guarded call on a child
  namespace, verified manually, matching the project's compile-fail convention.

### Shell integration, in `src/completion_test.zig`, under `zig build completion-test`

The file imports the public `dap` module (it exercises the consumer surface),
builds one small CLI declaration and one `app_name` (for example
`dap-completion-test`), generates all three scripts, and writes them into
`std.testing.tmpDir`. It then runs, per shell, only when the shell is present.
`zig build test` does not compile or run this file.

- **Syntax:** `bash -n script`, `zsh -n script`, `fish -n script`.
- **bash semantics:** source the script, set `COMP_WORDS`/`COMP_CWORD`, call
  `_dap_<ident>`, and assert `COMPREPLY`: a root flag prefix; a child command
  after a command token; an ancestor flag on a child level; an enumeration value
  after `--color`; an eq value with `COMP_WORDS=(app --color = r)` and
  `COMP_CWORD=3`; an empty eq value with `COMP_WORDS=(app --color =)` and
  `COMP_CWORD=2` (expecting `=red`); a non-enum value flag yielding empty
  `COMPREPLY`; and the literal state after `--`.
- **fish semantics:** `fish --no-config -c 'source script.fish; complete -C "app --co"'`,
  plus `complete -C "app --color "`, `complete -C "app --color=r"`, a command
  token, and a `--` line. Assert the tab-separated candidate/description
  output.
- **zsh:** syntax check and a smoke check that sourcing the script inside
  `compinit` defines the function and does not error. Semantic zsh completion
  needs a real completion context (`zpty`, an interactive `compinit` session, or
  a captured `compadd` invocation) and stays a manual check; it is not part of
  the step.
- **Registration:** assert the generated text registers exactly `app_name`, not
  `App.name`, and that a different `app_name` produces a different identifier
  and registration.
- **Missing shells:** a missing shell is skipped with a visible notice rather
  than failing the step, because `completion-test` is an explicit opt-in and
  developer machines rarely have all three. CI that wants a hard guarantee
  installs all three and treats the step's output as required.

No external shell is required for `zig build test`. Optional manual checks
during development:

```sh
app completion bash | bash -n
app completion zsh  | zsh -n
app completion fish | fish -n
```

## Non-goals for v1

- Dynamic runtime callbacks or user-provided value providers.
- Completing custom value types (only `Enumeration` is enumerable).
- Positional-argument value completion and precise file filtering.
- Pruning `Alt` branches after activation.
- Resolving `i18n` references.
- Multi-name registration in one script, renamed binaries or symlinked
  invocation names (generate one script per name).
- PowerShell, nu, elvish or other shells.
- Using zsh `_arguments` or bash-completion's `_init_completion`.

## Risks to verify during implementation

- bash `=` wordbreak: the scan lookahead, `$prev == '='` for the eq position,
  and the no-wordbreak fallback. This is the most likely place for a silent
  off-by-one.
- zsh `compadd -d` display semantics (`-V '' -l` for aligned one-per-line
  descriptions), `PREFIX` filtering with full `--long=value` candidates, and the
  `funcstack` guard in both autoload and sourced modes.
- fish eq-token replacement (`--color=r` plus a full `--color=red` candidate),
  `commandline -opc`/`-ct` at the cursor, and tab-separated descriptions under
  `complete -C`.
- bash 3.2 compatibility; `compopt` is unavailable, so per-call disabling of the
  default file fallback is not possible.
- Candidate names containing spaces (arrays and quoted arguments), colons (why
  `compadd -d` beats `_describe`), and newlines/tabs (not representable in
  fish's line protocol).
- Sanitized identifier collisions (`a-b` and `a_b`) when two dap CLIs are
  sourced into one bash or fish session; zsh is namespaced by the function name.
- `#compdef` parsing of punctuation in `app_name`; the `app_name` charset exists
  to keep this safe.
- Large trees: compile-time table construction and emitted script size; no
  laziness is planned.
