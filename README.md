# retro68-setup

A friendly command-line tool for installing and managing the [Retro68](https://github.com/autc04/Retro68) toolchain on macOS. Retro68 is a GCC-based cross-compilation environment for classic Motorola 68K and PowerPC Macintosh computers.

## Why This Tool?

Setting up Retro68 from the official documentation can be confusing and involves many manual steps. This tool:

- **Guides you through installation** with an interactive wizard
- **Manages dependencies** automatically via Homebrew
- **Handles Universal Interfaces** - switch between the open-source Multiversal interfaces and Apple's proprietary ones
- **Makes building samples easy** with interactive project and target selection
- **Provides clean uninstall** to easily remove everything and start fresh

## Requirements

- macOS 13.0 or later
- [Homebrew](https://brew.sh) (the tool will check for this)
- Xcode Command Line Tools

## Installation

### From Source

```bash
git clone https://github.com/mathieutozer/retro68-setup.git
cd retro68-setup
swift build -c release
sudo cp .build/release/retro68-setup /usr/local/bin/
```

### Development Build

```bash
swift build
.build/debug/retro68-setup --help
```

## Usage

### Check Status

```bash
retro68-setup status
```

Shows whether Retro68 is installed, which build targets are available, and which Universal Interfaces are active.

### Install Retro68

```bash
retro68-setup install
```

The interactive installer will:

1. **Check dependencies** - Verify Homebrew packages (cmake, boost, gmp, mpfr, libmpc, bison, texinfo) and offer to install any that are missing

2. **Clone the repository** - Download Retro68 and all submodules

3. **Select build targets** - Choose which platforms to build for:
   - **68K** - Classic Macs (Mac Plus through early Power Macs in emulation mode)
   - **PowerPC** - Power Macintosh with classic Mac OS
   - **Carbon** - PowerPC with Carbon API (Mac OS 8.1+)

4. **Build the toolchain** - Compiles GCC, binutils, and all Retro68 components

#### Install Options

```bash
retro68-setup install --skip-deps      # Skip dependency checking
retro68-setup install --skip-clone     # Use existing repository
retro68-setup install --rebuild-only   # Rebuild only Retro68 code, not GCC/binutils
```

### Manage Universal Interfaces

Retro68 needs interface headers and libraries to compile Mac programs. Two options exist:

#### Multiversal Interfaces (Default)

Open-source reimplementation included with Retro68. Limitations:
- No Carbon support
- No MacTCP, OpenTransport, Navigation Services
- Missing features introduced after System 7.0

#### Apple Universal Interfaces

Apple's proprietary interfaces provide full API coverage. To add them:

```bash
retro68-setup interfaces info    # Show instructions for obtaining interfaces
retro68-setup interfaces add     # Interactive setup
```

You'll need to obtain MPW (Macintosh Programmer's Workshop) Golden Master, which contains the InterfacesAndLibraries folder. Common sources include Archive.org and Macintosh Garden.

#### Interface Commands

```bash
retro68-setup interfaces list              # Show available interfaces
retro68-setup interfaces use multiversal   # Switch to Multiversal
retro68-setup interfaces use 3.4           # Switch to Apple UI version 3.4
retro68-setup interfaces remove 3.4        # Remove a version
```

### Build Sample Applications

```bash
retro68-setup build
```

Interactively select a sample project and target platform. The tool runs CMake and Make, then shows you where the output files are located.

```bash
retro68-setup build --project Dialog --target 68k   # Build specific project
retro68-setup build --clean                          # Clean build directory first
```

### Uninstall

```bash
retro68-setup uninstall
```

Removes the entire `~/.retro68` directory. Use `--keep-interfaces` to preserve any Apple Universal Interfaces you've added.

```bash
retro68-setup uninstall --keep-interfaces  # Keep Apple interfaces
retro68-setup uninstall --force            # Skip confirmation prompt
```

## Directory Structure

Everything is installed to `~/.retro68/`:

```
~/.retro68/
├── Retro68/                    # Source repository
├── Retro68-build/              # Build output
│   ├── toolchain/              # Compiled toolchain
│   │   ├── bin/                # Cross-compiler binaries
│   │   ├── m68k-apple-macos/   # 68K target files
│   │   └── powerpc-apple-macos/# PPC target files
│   ├── build-target/           # 68K sample builds
│   ├── build-target-ppc/       # PPC sample builds
│   └── build-target-carbon/    # Carbon sample builds
├── interfaces/                 # Interface storage
│   └── apple/                  # Apple Universal Interfaces
│       └── 3.4/               # Version 3.4
└── config.json                # Tool configuration
```

## Using the Toolchain Manually

After installation, you can use the toolchain directly with CMake:

```bash
# 68K
cmake -DCMAKE_TOOLCHAIN_FILE=~/.retro68/Retro68-build/toolchain/m68k-apple-macos/cmake/retro68.toolchain.cmake ..

# PowerPC Classic
cmake -DCMAKE_TOOLCHAIN_FILE=~/.retro68/Retro68-build/toolchain/powerpc-apple-macos/cmake/retroppc.toolchain.cmake ..

# PowerPC Carbon
cmake -DCMAKE_TOOLCHAIN_FILE=~/.retro68/Retro68-build/toolchain/powerpc-apple-macos/cmake/retrocarbon.toolchain.cmake ..
```

## Output Formats

Built applications come in several formats:

- `.bin` - MacBinary II format, suitable for transfer to real Macs
- `.dsk` - Disk image that can be mounted in emulators
- `.APPL` - Raw application file
- `.rsrc/` - AppleDouble resource fork format

## Troubleshooting

### Build fails during GCC compilation

The GCC build is very resource-intensive. Ensure you have:
- At least 10GB free disk space
- 8GB+ RAM recommended
- Stable internet connection for downloading sources

If the build fails partway through, you can often resume with:
```bash
retro68-setup install --skip-clone
```

### "Command not found" errors

Ensure Homebrew's bin directory is in your PATH:
```bash
export PATH="/opt/homebrew/bin:$PATH"  # Apple Silicon
export PATH="/usr/local/bin:$PATH"     # Intel
```

### Apple Universal Interfaces not working

Ensure you've:
1. Extracted the InterfacesAndLibraries folder from MPW
2. Used `retro68-setup interfaces add` to install them
3. Switched to them with `retro68-setup interfaces use <version>`

## License

This tool is provided as-is for managing Retro68 installations. Retro68 itself is licensed under the GPL. Apple Universal Interfaces are proprietary Apple software.

## Links

- [Retro68 GitHub Repository](https://github.com/autc04/Retro68)
- [Retro68 Documentation](https://github.com/autc04/Retro68/wiki)
- [Homebrew](https://brew.sh)
