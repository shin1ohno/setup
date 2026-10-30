# MCP Server Configuration

MCP server configurations belong in **`.mcp.json`** at the project root — NOT in `.claude/settings.local.json` or `.claude/settings.json`.

Format:
```json
{
  "mcpServers": {
    "name": {
      "type": "stdio",
      "command": "/absolute/path/to/binary",
      "args": ["--flag", "value"]
    }
  }
}
```

- Use absolute paths for the command binary (avoid `cargo run` — too slow for MCP startup)
- MCP servers must respond to `initialize` immediately — no startup sleep
- For SSE transport, use `--transport sse --http-port <port>` and the client connects via HTTP

## `claude mcp list` の Connected は認証・接続の証拠にしない

`claude mcp list` / `claude mcp get` の Connected は「サーバが initialize に応答した」以上を意味しない。claude.ai スコープの Google 系コネクタ（`*mcp.googleapis.com/mcp/v1`）は未認証の initialize に 200 を返すため、claude.ai で切断した後も Connected と表示される（Notion / Slack / Figma は 401 で Needs authentication になる）。ツールが実際に注入されるかは、新規セッションの ToolSearch か、陽性対照つきの headless 多回 probe（`~/.claude/docs/claude-cli-headless.md`）で判定する。SessionStart の health hook もこの Connected を信じるので、Google 系の認証切れは検出できない。

Origin: 2026-10-30、直接登録 13 本を claude.ai で切断した後に Google 6 本だけが Connected のまま見え、切断失敗と誤読した件。
