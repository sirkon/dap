# Completion scripts generator.

I want to create a completion shell scripts generator for this library.

Its public API must look like

```zig
CLI.completion(arena, .zsh); // returns []const u8
```

with the support for `zsh`, `bash` and `fish`. With no view argument, the instantiation value is clearly not needed for
this (correct me if I am wrong).
