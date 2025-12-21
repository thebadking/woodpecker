# Depth-Based Directory Scanning for Configuration Files

## Overview

This feature adds configurable depth-based directory scanning for Woodpecker CI configuration files, allowing you to organize pipeline configurations in subdirectories instead of requiring a flat file structure.

## Features

### 1. **Configurable Scan Depth**
- **Field**: `config_path_depth` (integer, default: `0`)
- **Behavior**:
  - `0` (default): Only scans the root of the config directory (backward compatible)
  - `1`: Scans root + one level of subdirectories
  - `2`: Scans root + two levels of subdirectories
  - And so on...

### 2. **Template File Filtering**
- **Field**: `ignore_template_files` (boolean, default: `false`)
- **Behavior**: When enabled, files containing "template" in their name are ignored (case-insensitive)
- **Use Case**: Allows you to store reusable YAML templates alongside your pipeline configs without them being executed

### 3. **Unique File Name Validation**
- Automatically validates that all discovered config files have unique base names
- Prevents conflicts when files in different subdirectories have the same name
- Example: `.woodpecker/main.yml` and `.woodpecker/ci/main.yml` would trigger an error

## Example Directory Structure

### Before (Flat)
```
.woodpecker/
├── build.yml
├── test.yml
├── deploy.yml
└── lint.yml
```

### After (Organized with Depth Scanning)
```
.woodpecker/                    # depth 0
├── main.yml
├── ci/                         # depth 1
│   ├── unit-tests.yml
│   ├── integration-tests.yml
│   └── lint.yml
├── deploy/                     # depth 1
│   ├── staging.yml
│   └── production.yml
└── templates/                  # depth 1 (ignored if ignore_template_files=true)
    └── base-template.yml
```

With `config_path_depth: 1`, all `.yml` and `.yaml` files at depth 0 and 1 will be discovered and executed.

## Configuration

### Global Defaults (Environment Variables)

Set default values for all new repositories by adding these to your `.env` file:

```env
# Default depth for scanning config subdirectories (default: 0)
WOODPECKER_DEFAULT_CONFIG_PATH_DEPTH=1

# Default setting for ignoring template files (default: false)
WOODPECKER_DEFAULT_IGNORE_TEMPLATE_FILES=true
```

**These defaults only apply to newly activated repositories.** Existing repositories keep their current settings.

### Per-Repository Configuration

You can configure these settings for individual repositories:

#### Via Woodpecker UI
1. Navigate to Repository Settings → General
2. Set "Config Directory Scan Depth" (0-10)
3. Enable/disable "Ignore template files"
4. Click "Save settings"