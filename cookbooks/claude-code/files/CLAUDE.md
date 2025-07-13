# Claude Code Personal Preferences

This file contains my personal preferences for Claude Code.

## General Instructions

- Please communicate in Japanese
- Git commit messages and comments in source code should be in English
- Please never include things like "Generated with [Claude Code](https://claude.ai/code)" or "Co-Authored-By: Claude <noreply@anthropic.com>" in git commit messages
- Always ensure files end with a newline character (`\n`)
- Follow existing code conventions and patterns in each project
- Prefer editing existing files over creating new ones
- Create a SESSION_PROGRESS.md document at the project root. Always record plans and achievements here, and constantly refer to and update it as we progress. Consider to split SESSION_PROGRESS.md appropriately to conserve tokens
- Please make the most of Gemini and o3 as good consultants. I have written their respective characters and access methods below for your reference

## Code Quality Standards

- Throw errors instead of silently ignoring them (unless explicitly instructed otherwise)
- Do not leave empty lines containing only whitespace
- Write clean, readable code that follows language conventions
- Use consistent indentation and formatting
- Do not use mock data in the production code

## Using o3

You have three o3 mcps installed. Leverage their web search capability which enable you to get to know the latest information. They have general knowledge and high reasoning capabililty.

## Using Gemini AI

When analyzing large codebases or multiple files that might exceed context limits or you want to search the web, use the Gemini CLI with its massive context window. Use `gemini -p` to leverage Google Gemini's large context capacity.

## File and Directory Inclusion Syntax

Use the `@` syntax to include files and directories in your Gemini prompts. The paths should be relative to WHERE you run the
gemini command:

### How to use

- Single file analysis: gemini -p "@src/main.py Explain this file's purpose and structure"
- Multiple files: gemini -p "@package.json @src/index.js Analyze the dependencies used in the code"
- Entire directory: gemini -p "@src/ Summarize the architecture of this codebase"
- Multiple directories: gemini -p "@src/ @tests/ Analyze test coverage for the source code"
- Current directory and subdirectories: gemini -p "@./ Give me an overview of this entire project"
- Web search: gemini -p "WebSearch: oauth 2.0 security best practices rfc"

### Implementation Verification Examples

Check if a feature is implemented: gemini -p "@src/ @lib/ Has dark mode been implemented in this codebase? Show me the relevant files and functions"
Verify authentication implementation: gemini -p "@src/ @middleware/ Is JWT authentication implemented? List all auth-related endpoints and middleware"
Check for specific patterns: gemini -p "@src/ Are there any React hooks that handle WebSocket connections? List them with file paths"
Verify error handling: gemini -p "@src/ @api/ Is proper error handling implemented for all API endpoints? Show examples of try-catch blocks"
Check for rate limiting: gemini -p "@backend/ @middleware/ Is rate limiting implemented for the API? Show the implementation details"
Verify caching strategy: gemini -p "@src/ @lib/ @services/ Is Redis caching implemented? List all cache-related functions and their usage"
Check for specific security measures: gemini -p "@src/ @api/ Are SQL injection protections implemented? Show how user inputs are sanitized"
Verify test coverage for features: gemini -p "@src/payment/ @tests/ Is the payment processing module fully tested? List all test cases"

### When to Use Gemini CLI

Use gemini -p when:

- Analyzing entire codebases or large directories
- Comparing multiple large files
- Need to understand project-wide patterns or architecture
- Current context window is insufficient for the task
- Working with files totaling more than 100KB
- Verifying if specific features, patterns, or security measures are implemented
- Checking for the presence of certain coding patterns across the entire codebase

### Important Notes

- Paths in @ syntax are relative to your current working directory when invoking gemini
  - The CLI will include file contents directly in the context
- Gemini's context window can handle entire codebases that would overflow Claude's context
- When checking implementations, be specific about what you're looking for to get accurate results # Using Gemini CLI for Large Codebase Analysis
