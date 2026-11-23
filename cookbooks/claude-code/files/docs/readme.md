# README Authoring — Structure, Facts, Comparison, Checklist

Load when writing, rewriting or reviewing a README for a library, crate, CLI tool or service. A project's established README style wins when improving an existing one. Adapted from sorah/config `sorah-guides/skills/readme`.

A README lets a stranger decide within one screen whether the project solves their problem, then gets them to a working first use. Everything else must earn its place.

## Workflow

1. **Gather facts from the repository; never invent them.**
   - Name, package name and registry (`Cargo.toml`, `*.gemspec`, `package.json`, `go.mod`).
   - Install channels that actually exist: crates.io / RubyGems release, Homebrew tap, container image, GitHub release binaries (read the release workflow), a cookbook in `~/ManagedProjects/setup`.
   - Minimum runtime (`rust-version`, `required_ruby_version`, `engines`).
   - Real `--help` output and real config samples in the repo.
   - `LICENSE*` and copyright holder; `SECURITY.md`, `CONTRIBUTING.md`, `docs/`.
   - Upstream projects it wraps, replaces or was inspired by.
2. Pick the shape: foundational library (very short), focused library (example-driven), CLI tool (install matrix + usage + config + comparison), service/daemon (how it works + setup + configuration + security model + caveats).
3. Write the title, tagline and first paragraph first. If they cannot be written in two sentences, the positioning is unclear — ask the owner instead of padding.
4. Write the smallest working example, then the remaining sections.
5. **Verify every command, path, flag and link against the repository**; run the example when feasible.
6. Review against the checklist below.

## Skeleton

Omit any section with nothing true to say.

```
# Name: tagline
Intro paragraph
## Features / Why
## Requirements
## Installation
## Usage
## Configuration
## How it works            (services, security-sensitive tools)
## Comparison / Prior art
## Security model
## Caveats
## Development
## License
```

## Opening

- Title: `# Name: short noun-phrase tagline`, no trailing period.
- First paragraph: "X is a [category] that [does what] [for whom/where]." Anchor to a known tool ("alternative to `find`"), credit prior art, use two or three concrete adjectives rather than superlatives, and admit a defining limit early.
- Nothing above the pitch except badges.

## Examples

- The smallest runnable example sits in the first screen of Usage.
- Copy-pasteable commands; `$ ` prefix only when output is shown (`console` fence).
- Config and source blocks start with a filename comment (`# ~/.config/foo.toml`) and carry a language tag.
- Document CLI subcommands and config keys with end-of-line comments and their defaults.
- Placeholders: `example.com`, `123456789012`, `ALL_CAPS` for arguments.

## Evidence over adjectives

- **Comparison with alternatives** (`### vs. X`): say when the alternative is the better choice. This is the section that makes the rest believable.
- **Why not / When not to use** for the same reason.
- Benchmarks only with workload, hardware and a reproducible script. Never estimate numbers.
- **Caveats** as a list of hard limits, not an "experimental" banner.
- Badges optional, 2-4 that answer a reader question (version, CI, docs). No dead services, no self-asserted coverage, no stars.

## Voice

- Plain, factual, third person for the project.
- Sentence-case headings, ATX only.
- Machine-written tells to remove: em dashes, bold lead-ins on every bullet, "Whether you're X or Y", "seamless", "robust", "powerful", emoji headers, a closing summary paragraph.

## Checklist

- [ ] Every install channel, flag, config key and path exists in the repo today.
- [ ] The first screen answers what it is, who it is for, and how to try it.
- [ ] The minimal example was run, or its commands match `--help`.
- [ ] Comparison or Caveats states at least one case where this project is the wrong choice (tools and services).
- [ ] License text matches `LICENSE*` exactly.
- [ ] No leftover template text, stale version numbers in prose, or fabricated users/benchmarks.
