# fzf-tab Cookbook

This cookbook installs and configures the [fzf-tab](https://github.com/Aloxaf/fzf-tab) plugin for Zsh, which provides enhanced tab completion using fzf.

## Features

- Replaces Zsh's default completion selection menu with fzf
- Enables preview for various command completions
- Supports group selection with headers
- Colorizes filename completions

## Dependencies

This cookbook depends on:
- `fzf` cookbook (already included in the core role)
- `zsh` cookbook (already included in the core role)

## Usage

Simply include this cookbook in your role after the `fzf` and `zsh` cookbooks:

```ruby
include_cookbook "fzf-tab"
```

## Configuration

The cookbook sets up basic configuration to:

- Format completion descriptions to enable group support
- Set list-colors to enable filename colorizing
- Enable directory preview with `ls -la` when completing `cd` commands

For additional configuration options, refer to the [fzf-tab GitHub repository](https://github.com/Aloxaf/fzf-tab).