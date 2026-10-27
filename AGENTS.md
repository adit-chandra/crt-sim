# Agent notes

See `README.md` for what the app does, how to build it, and the source layout.

## Worktrees

Create git worktrees only under `.worktrees/` in the repo root. Never put them
in the parent directory next to the repo.

```sh
git worktree add .worktrees/<branch> -b <branch>
git worktree remove .worktrees/<branch>   # when you're done
```

`.worktrees/` is gitignored.
