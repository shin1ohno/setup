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
