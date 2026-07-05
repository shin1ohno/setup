# Frontend Dev Guidelines (Node.js / Next.js / Vite)

## `npm install` after any upstream change

After every `git rebase`, `git merge`, or `git pull` in a project that has `package.json`, check whether the manifest changed:

```bash
git diff ORIG_HEAD HEAD -- package.json package-lock.json
```

If either file changed, run the project's install command (`npm install` / `pnpm install` / `yarn install`) **before** any build, test, or dev-server run. Do not wait for `Cannot find module '<x>'` errors to reveal stale `node_modules`.

This applies equally to worktree-based sub-agents: after `git merge origin/main` resolves a conflict involving `package.json`, `npm install` is part of the merge-resolution cycle, not a follow-up.

## Sub-agent dev-server host binding

When a sub-agent launches a JS dev server for verification, bind to `0.0.0.0` and access it via `127.0.0.1:<port>` rather than `localhost:<port>`. `localhost` does not always resolve inside sub-agent sandboxes the same way it does on the host, which surfaces as spurious "connection refused" in otherwise-valid verification loops.

- Next.js (15+): `next dev --port <port> --hostname 0.0.0.0`
- Vite: `vite --host 0.0.0.0 --port <port>`

## `allowedDevOrigins` when accessing dev from a LAN hostname

Next.js 15+ blocks cross-origin HMR by default for safety. If you access the dev server from a LAN hostname (e.g. `pro.home.local:3000`) instead of `localhost`, HMR gets blocked, hydration can fail silently, and data-driven panels show up empty even though `npm run build` is green. Fix by adding the hostname to `next.config.ts`:

```ts
const nextConfig: NextConfig = {
  // ... existing config
  allowedDevOrigins: ["pro.home.local"],
};
```

This is dev-only; production builds ignore the field.
