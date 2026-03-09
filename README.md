# quay-ref-promoter

An interactive bash script to assist with promoting git refs to production namespaces in app-interface for Quay.io services.

![Recording of the application](./demo.gif)

## Overview

This tool simplifies the process of updating git references (branches, tags, commits) across multiple deployments in app-interface SAAS files. It provides an interactive terminal UI to select repositories, view active deployments, and update refs across one or many namespaces simultaneously.

## Installation
1. Clone this repo.
1. Install [gum](https://github.com/charmbracelet/gum?tab=readme-ov-file#installation)
1. Install [yq](https://github.com/mikefarah/yq#install)
1. Run `make install` to install into `$HOME/.local/bin` (customizable with `$INSTALL_DIR` in Makefile)
1. `export APP_INTERFACE_PATH=/path/to/app-interface` in your bash/zsh/other shell's config file

- Then, you can run `promote-quay-refs.sh` in your shell to execute the script.
- Run `make uninstall` to remove the script.

## Features

- Interactive TUI powered by [gum](https://github.com/charmbracelet/gum)
- Support for both `quayio` and `registry-proxy` services
- Multi-select capability to update multiple deployments at once
- Automatically scans and displays all active deployments (excluding disabled or main/master refs)
- Shows deployment counts per repository
- Safe updates with confirmation prompts

## Prerequisites

- **gum** - Terminal UI toolkit ([installation guide](https://github.com/charmbracelet/gum#installation))
- **yq** - YAML processor ([installation guide](https://github.com/mikefarah/yq#install))
- **bash 4+** - Bash shell (comes standard on Linux; macOS ships with Bash 3.x which is not supported — install a newer version via `brew install bash`)

### Basic Usage

```bash
./promote-quay-refs.sh [APP_INTERFACE_PATH]
```

### Using Environment Variable

```bash
export APP_INTERFACE_PATH=/path/to/app-interface
./promote-quay-refs.sh
```

If no path is provided, the script uses the current working directory.

### Demo / Testing

A `data/` directory is included with dummy SAAS files for testing and demonstration:

```bash
./promote-quay-refs.sh ./data
```

This demo data contains fake repositories and deployments that let you explore the tool's functionality without accessing real app-interface data. See [data/README.md](data/README.md) for details.

## Workflow

1. **Select Service**: Choose between `quayio`, `registry-proxy`, or `both`
2. **Repository Selection**: Pick from a list of repositories with deployment counts
3. **Deployment Selection**: Choose one or more deployments to update (use Space to select, Enter to confirm)
4. **Enter New Ref**: Specify the new git ref (branch, tag, or commit SHA)
5. **Confirm**: Review and confirm the changes
6. **Complete**: Files are updated and ready for commit

## Directory Structure

The script expects the following directory structure in your app-interface repository:

```
app-interface/
├── data/
│   └── services/
│       ├── quayio/
│       │   └── saas/
│       │       └── *.yaml
│       └── registry-proxy/
│           └── saas/
│               └── *.yaml
```
