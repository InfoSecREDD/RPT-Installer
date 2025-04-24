#!/bin/bash
# REDD's SteamOS Steam Deck Pentest Tools Installer
#
# This script installs penetration testing tools to the Steam Deck,
# prioritizing installation to the home directory to conserve system partition space.
# 
# Enjoy!

# Parse command line arguments
parse_arguments() {
    UNINSTALL=false
    # Make LOCAL_INSTALL true by default - most SteamOS systems have limited system partition space
    LOCAL_INSTALL=true
    SYSTEM_INSTALL=false
    FORCE_CLEANUP=false
    EMERGENCY_CLEANUP=false

    for arg in "$@"; do
        case $arg in
            --uninstall)
                UNINSTALL=true
                shift
                ;;
            --local)
                LOCAL_INSTALL=true
                SYSTEM_INSTALL=false
                shift
                ;;
            --system)
                SYSTEM_INSTALL=true
                LOCAL_INSTALL=false
                shift
                ;;
            --force-cleanup)
                FORCE_CLEANUP=true
                shift
                ;;
            --emergency-cleanup)
                EMERGENCY_CLEANUP=true
                shift
                ;;
            *)
                # Unknown option
                ;;
        esac
    done
}

set -e  # Exit immediately if a command exits with non-zero status

# Function for error handling
handle_error() {
    echo "ERROR: $1"
    exit 1
}

# Function to check available disk space (in MB)
check_disk_space() {
    local path=$1
    if [ -z "$path" ]; then
        path="/"
    fi
    local free_space
    free_space=$(df -m "$path" | awk 'NR==2 {print $4}')
    echo "$free_space"
}

# Function to clean up disk space when needed
cleanup_disk_space() {
    echo "Attempting to free up disk space..."

    # Clear pacman cache
    echo "Clearing pacman cache..."
    sudo rm -rf /var/cache/pacman/pkg/* 2>/dev/null || true
    
    # Clean package cache
    sudo pacman -Scc --noconfirm 2>/dev/null || true
    
    # Remove old logs
    echo "Removing old logs..."
    sudo rm -rf /var/log/*.gz /var/log/*/*.gz 2>/dev/null || true
    sudo find /var/log -type f -name "*.log" -exec truncate -s 0 {} \; 2>/dev/null || true
    
    # Clean temporary files
    echo "Cleaning temporary files..."
    sudo rm -rf /tmp/* /var/tmp/* 2>/dev/null || true
    
    # Clean journal logs
    echo "Clearing systemd journal logs..."
    sudo journalctl --vacuum-time=1d 2>/dev/null || true
    
    # Clean up user cache
    echo "Cleaning user cache directories..."
    rm -rf ~/.cache/* 2>/dev/null || true
    
    # Remove downloaded sources
    echo "Removing source packages..."
    rm -rf ~/pentest-tools/src/* 2>/dev/null || true
    
    # If we're desperate for space - remove downloaded tools
    if [ "$FORCE_CLEANUP" = true ]; then
        echo "FORCE CLEANUP: Removing additional directories..."
        rm -rf ~/pentest-tools/SecLists 2>/dev/null || true
        rm -rf ~/.cache 2>/dev/null || true
        sudo find /var -name "*.log" -delete 2>/dev/null || true
    fi

    # Check new free space
    local free_space
    free_space=$(check_disk_space)
    echo "Freed up space. Current free space: ${free_space}MB"
    
    # If still low on space, provide guidance
    if [ "$free_space" -lt 100 ]; then
        echo "WARNING: Still low on disk space. Consider manually removing large files."
        echo "You can run: du -h -d 2 /home | sort -hr | head -20"
        echo "to find large directories to clean up."
    fi
}

# Function to get secure confirmation
confirm() {
    # Check if stdin is a terminal
    if [ -t 0 ]; then
        # Generate random confirmation code for security
        CONFIRM_CODE=$(cat /dev/urandom | tr -dc 'a-zA-Z0-9' | fold -w 6 | head -n 1)
        
        echo -e "\n$1"
        echo "To confirm, please type exactly: $CONFIRM_CODE"
        read -r user_input
        
        if [ "$user_input" != "$CONFIRM_CODE" ]; then
            echo "Confirmation failed. Exiting..."
            exit 1
        fi
    else
        echo "ERROR: This script requires interactive input. Do not pipe commands to this script."
        echo "Please run the script directly in a terminal."
        exit 1
    fi
}

# Function to check if running on SteamOS
check_steamos() {
    if ! grep -q "SteamOS" /etc/os-release; then
        echo "WARNING: This script is designed for SteamOS on Steam Deck."
        confirm "Type the confirmation code to continue anyway:"
    fi
}

# Function to set up local installation directory structure
setup_local_dirs() {
    echo "Setting up local installation directories..."
    mkdir -p ~/pentest-tools/bin
    mkdir -p ~/pentest-tools/src
    mkdir -p ~/.local/bin
    mkdir -p ~/.local/lib
    mkdir -p ~/.local/share
    
    # Ensure PATH includes local bin directories
    if ! grep -q "$HOME/.local/bin" ~/.bashrc; then
        echo 'export PATH="$HOME/.local/bin:$HOME/pentest-tools/bin:$PATH"' >> ~/.bashrc
        echo 'export LD_LIBRARY_PATH="$HOME/.local/lib:$LD_LIBRARY_PATH"' >> ~/.bashrc
    fi
    
    # Add to .zshrc if it exists
    if [ -f ~/.zshrc ] && ! grep -q "$HOME/.local/bin" ~/.zshrc; then
        echo 'export PATH="$HOME/.local/bin:$HOME/pentest-tools/bin:$PATH"' >> ~/.zshrc
        echo 'export LD_LIBRARY_PATH="$HOME/.local/lib:$LD_LIBRARY_PATH"' >> ~/.zshrc
    fi
    
    # Make PATH changes take effect immediately for this session
    export PATH="$HOME/.local/bin:$HOME/pentest-tools/bin:$PATH"
    export LD_LIBRARY_PATH="$HOME/.local/lib:$LD_LIBRARY_PATH"
    
    # Create a standalone PATH setup script
    cat > ~/setup-pentest-path.sh << 'EOL'
#!/bin/bash
# Source this file to set up penetration testing tools PATH
export PATH="$HOME/.local/bin:$HOME/pentest-tools/bin:$PATH"
export LD_LIBRARY_PATH="$HOME/.local/lib:$LD_LIBRARY_PATH"
echo "Penetration testing tools PATH has been set up."
echo "You can now run tools directly by their names (e.g., 'wifite', 'sqlmap', etc.)"
EOL
    chmod +x ~/setup-pentest-path.sh
    
    # Source the PATH for current shell if running interactively
    source ~/setup-pentest-path.sh
    
    echo "Local directories set up and PATH configured."
    echo "NOTE: You may need to restart your terminal or run: source ~/setup-pentest-path.sh"
}

# Function to check free home directory space and warn if low
check_home_space() {
    local free_space
    free_space=$(check_disk_space "$HOME")
    echo "Free space in home directory: ${free_space}MB"
    
    if [ "$free_space" -lt 1000 ]; then
        echo "WARNING: Low space in home directory (${free_space}MB)."
        echo "You may not have enough space for all tools."
        confirm "Continue with installation anyway?"
    fi
}

# Function to install pacman packages with error handling
install_pacman_package() {
    # Check available space on system partition before installing
    local sys_space
    sys_space=$(check_disk_space)
    
    # If system space is critically low, try to clean up first
    if [ "$sys_space" -lt 50 ]; then
        echo "WARNING: Critically low system partition space (${sys_space}MB). Attempting cleanup..."
        cleanup_disk_space
        sys_space=$(check_disk_space)
        
        # If still below 30MB after cleanup, show warning
        if [ "$sys_space" -lt 30 ]; then
            echo "CRITICAL: System partition has only ${sys_space}MB free."
            echo "Installation of system packages may fail."
            echo "Consider running with fewer tools or using --force-cleanup."
        fi
    fi
    
    echo "  --> Installing $1"
    if ! pacman -Ss "^$1$" >/dev/null 2>&1; then
        echo "WARNING: Package $1 not found in repositories, skipping..."
        return 1
    fi
    sudo pacman -S "$1" --noconfirm || echo "WARNING: Failed to install $1, continuing..."
    return 0
}

# Function to install minimally required system packages
install_minimal_system_packages() {
    echo "Installing minimal required system packages..."
    # Very conservative list of essential tools that must be system-installed
    ESSENTIAL_SYS_TOOLS=("git" "base-devel" "python-pip")
    for tool in "${ESSENTIAL_SYS_TOOLS[@]}"; do
        install_pacman_package "$tool"
    done
}

# Function to install AUR packages with error handling
install_aur_package() {
    echo "  --> Installing $1 from AUR (local installation)"
    # Use makepkg with custom paths for local installation
    cd ~/pentest-tools/src || return 1
    if [ -d "$1" ]; then
        rm -rf "$1"
    fi
    git clone "https://aur.archlinux.org/$1.git" || return 1
    cd "$1" || return 1
    
    # Modify PKGBUILD to use home directory if possible
    if [ -f "PKGBUILD" ]; then
        # Try to modify the PKGBUILD to install to local directory
        sed -i "s|--prefix=/usr|--prefix=$HOME/.local|g" PKGBUILD 2>/dev/null || true
        sed -i "s|-DCMAKE_INSTALL_PREFIX=/usr|-DCMAKE_INSTALL_PREFIX=$HOME/.local|g" PKGBUILD 2>/dev/null || true
        
        # Build and install the package
        makepkg -si --noconfirm || echo "WARNING: Failed to install $1 locally, continuing..."
    else
        # Fall back to regular installation if PKGBUILD not found
        yay -S "$1" --noconfirm || echo "WARNING: Failed to install $1, continuing..."
    fi
    cd ~/pentest-tools || return 1
}

# Function to install a tool from source to local directory
install_from_source() {
    local tool_name="$1"
    local git_url="$2"
    local build_cmd="$3"
    
    echo "  --> Building $tool_name from source (local installation)"
    cd ~/pentest-tools/src || return 1
    
    # Remove directory if it exists to ensure clean install
    if [ -d "$tool_name" ]; then
        rm -rf "$tool_name"
    fi
    
    # Clone the repository
    git clone --depth=1 "$git_url" "$tool_name" || return 1
    
    # Verify the directory exists before trying to enter it
    if [ ! -d "$tool_name" ]; then
        echo "ERROR: Repository directory $tool_name not found after cloning"
        return 1
    fi
    
    # Navigate to the tool directory
    cd "$tool_name" || {
        echo "ERROR: Failed to enter directory $tool_name"
        return 1
    }
    
    # Run the build command with error handling
    echo "Running build command in $(pwd)"
    eval "$build_cmd" || {
        echo "WARNING: Build command failed for $tool_name"
        cd ~/pentest-tools || return 1
        return 1
    }
    
    # Return to the pentest tools directory
    cd ~/pentest-tools || return 1
    return 0
}

# Function to download or clone security tools repository
clone_security_tools() {
    echo "Downloading security tools collection..."
    mkdir -p ~/pentest-tools/collections
    cd ~/pentest-tools/collections || return 1
    
    # Clone some useful repositories with small depth to save space
    git clone --depth=1 https://github.com/danielmiessler/SecLists.git seclists || true
    # Use a smaller wordlist collection to save space
    git clone --depth=1 https://github.com/praetorian-inc/Hob0Rules.git password-rules || true
    git clone --depth=1 https://github.com/swisskyrepo/PayloadsAllTheThings.git payloads || true
    
    cd ~/pentest-tools || return 1
}

# Function to install binary tools directly to local bin
install_binary_tool() {
    local tool_name="$1"
    local url="$2"
    
    echo "  --> Installing $tool_name binary"
    cd ~/pentest-tools/bin || return 1
    
    if [[ "$url" == *.zip ]]; then
        wget "$url" -O "$tool_name.zip" || return 1
        unzip "$tool_name.zip" || return 1
        rm "$tool_name.zip"
    elif [[ "$url" == *.tar.gz ]]; then
        wget "$url" -O "$tool_name.tar.gz" || return 1
        tar -xzf "$tool_name.tar.gz" || return 1
        rm "$tool_name.tar.gz"
    else
        wget "$url" -O "$tool_name" || return 1
        chmod +x "$tool_name"
    fi
    
    cd ~/pentest-tools || return 1
}

# Function to create a launcher script for a tool
create_launcher() {
    local tool_name="$1"
    local command="$2"
    
    echo "  --> Creating launcher for $tool_name"
    cat > ~/pentest-tools/bin/"$tool_name" << EOL
#!/bin/bash
# Launcher for $tool_name
$command "\$@"
EOL
    chmod +x ~/pentest-tools/bin/"$tool_name"
}

# Function to create a desktop entry for a tool
create_desktop_entry() {
    local tool_name="$1"
    local command="$2"
    local description="$3"
    local icon="utilities-terminal"
    
    mkdir -p ~/.local/share/applications/
    cat > ~/.local/share/applications/"$tool_name".desktop << EOL
[Desktop Entry]
Name=$tool_name
Comment=$description
Exec=$command
Icon=$icon
Terminal=true
Type=Application
Categories=Utility;Security;
EOL
}

# Function to install key Python-based security tools
install_python_tools() {
    echo "Installing Python-based security tools..."
    
    # Create directory for Python libraries
    mkdir -p ~/pentest-tools/lib/python
    
    # Create a simple script to install Python packages directly to our own lib directory
    cat > ~/pentest-tools/bin/safe-pip-install << 'EOL'
#!/bin/bash
# Safely install Python packages to local directory
PACKAGE=$1
echo "Installing $PACKAGE to local directory..."
python -m pip install --target="$HOME/pentest-tools/lib/python" $PACKAGE
EOL
    chmod +x ~/pentest-tools/bin/safe-pip-install
    
    # Create a script to run Python with our lib directory in the path
    cat > ~/pentest-tools/bin/pentest-python << 'EOL'
#!/bin/bash
# Run Python with our lib directory in the path
export PYTHONPATH="$HOME/pentest-tools/lib/python:$PYTHONPATH"
python "$@"
EOL
    chmod +x ~/pentest-tools/bin/pentest-python
    
    # Install Python tools using our custom method
    echo "Installing Python packages to local directory..."
    ~/pentest-tools/bin/safe-pip-install dnsrecon
    ~/pentest-tools/bin/safe-pip-install pwntools
    ~/pentest-tools/bin/safe-pip-install impacket

    # CrackMapExec needs special handling - install from source
    echo "Installing CrackMapExec from source..."
    install_from_source "crackmapexec" "https://github.com/byt3bl33d3r/CrackMapExec.git" \
        "python -m pip install -e . --target=$HOME/pentest-tools/lib/python || true && cp -r . ~/pentest-tools/src/crackmapexec-install"

    # Create proper CME launchers
    cat > ~/.local/bin/crackmapexec << 'EOL'
#!/bin/bash
export PYTHONPATH="$HOME/pentest-tools/lib/python:$PYTHONPATH"
python $HOME/pentest-tools/src/crackmapexec-install/cme/crackmapexec.py "$@"
EOL
    chmod +x ~/.local/bin/crackmapexec

    # Add symlink for cme command
    ln -sf ~/.local/bin/crackmapexec ~/.local/bin/cme
    
    # Common Python-based tools that are easy to install from source
    install_from_source "dirsearch" "https://github.com/maurosoria/dirsearch.git" \
        "~/pentest-tools/bin/safe-pip-install -r requirements.txt || true && cp -r . ~/pentest-tools/src/dirsearch-install"
    
    # Create a wrapper script that uses our Python environment
    cat > ~/.local/bin/dirsearch << 'EOL'
#!/bin/bash
export PYTHONPATH="$HOME/pentest-tools/lib/python:$PYTHONPATH"
python $HOME/pentest-tools/src/dirsearch-install/dirsearch.py "$@"
EOL
    chmod +x ~/.local/bin/dirsearch
    
    install_from_source "sqlmap" "https://github.com/sqlmapproject/sqlmap.git" \
        "cp -r . ~/pentest-tools/src/sqlmap-install"
    
    cat > ~/.local/bin/sqlmap << 'EOL'
#!/bin/bash
export PYTHONPATH="$HOME/pentest-tools/lib/python:$PYTHONPATH"
python $HOME/pentest-tools/src/sqlmap-install/sqlmap.py "$@"
EOL
    chmod +x ~/.local/bin/sqlmap
    
    install_from_source "sherlock" "https://github.com/sherlock-project/sherlock.git" \
        "~/pentest-tools/bin/safe-pip-install -r requirements.txt || true && cp -r . ~/pentest-tools/src/sherlock-install"
    
    cat > ~/.local/bin/sherlock << 'EOL'
#!/bin/bash
export PYTHONPATH="$HOME/pentest-tools/lib/python:$PYTHONPATH"
python $HOME/pentest-tools/src/sherlock-install/sherlock/sherlock.py "$@"
EOL
    chmod +x ~/.local/bin/sherlock
    
    install_from_source "theharvester" "https://github.com/laramies/theHarvester.git" \
        "~/pentest-tools/bin/safe-pip-install -r requirements/base.txt || true && cp -r . ~/pentest-tools/src/theharvester-install"
    
    cat > ~/.local/bin/theharvester << 'EOL'
#!/bin/bash
export PYTHONPATH="$HOME/pentest-tools/lib/python:$PYTHONPATH"
python $HOME/pentest-tools/src/theharvester-install/theHarvester.py "$@"
EOL
    chmod +x ~/.local/bin/theharvester
}

# Function to ensure tool commands are available in PATH
ensure_command_in_path() {
    local tool_name="$1"
    local tool_path="$2"
    
    echo "  --> Making $tool_name available in PATH"
    
    # Create symlink in ~/.local/bin (which is added to PATH)
    if [ -f "$tool_path" ]; then
        ln -sf "$tool_path" ~/.local/bin/"$tool_name"
        chmod +x ~/.local/bin/"$tool_name"
    else
        echo "  --> WARNING: Could not find $tool_path"
    fi
}

# Function to install wireless testing tools
install_wireless_tools() {
    echo "Installing Wifite and wireless testing dependencies..."
    
    # Install essential wireless tools
    install_pacman_package "aircrack-ng"
    install_pacman_package "wireless_tools"
    install_pacman_package "iw"
    
    # Clone and install Wifite - direct method for reliability
    mkdir -p ~/pentest-tools/src
    echo "Installing Wifite from source..."
    
    # Remove existing installation if present
    rm -rf ~/pentest-tools/src/wifite2 2>/dev/null || true
    
    # Clone the repository directly
    cd ~/pentest-tools/src
    if ! git clone --depth=1 https://github.com/derv82/wifite2.git; then
        echo "Failed to clone Wifite repository. Trying alternate method..."
        # Try downloading a snapshot instead
        wget -q https://github.com/derv82/wifite2/archive/refs/heads/master.zip -O wifite2.zip
        unzip -q wifite2.zip
        mv wifite2-master wifite2
    fi
    
    # Ensure wifite directory exists
    if [ ! -d ~/pentest-tools/src/wifite2 ]; then
        echo "ERROR: Failed to install Wifite. Please install manually."
    else
        # Find the main Wifite script (case-insensitive)
        WIFITE_MAIN=$(find ~/pentest-tools/src/wifite2 -type f -name "[Ww]ifite*.py" | head -n 1)
        echo "Found Wifite script at: $WIFITE_MAIN"
        
        # Create a robust launcher script that directly calls the found Python script
        cat > ~/.local/bin/wifite << EOL
#!/bin/bash
# Direct Wifite launcher

# Install dependencies if missing
if ! command -v aircrack-ng >/dev/null 2>&1; then
    echo "Aircrack-ng is missing. Installing..."
sudo pacman -S aircrack-ng --noconfirm
fi

# Define the path to the Wifite script
WIFITE_SCRIPT="$WIFITE_MAIN"

if [ -f "\$WIFITE_SCRIPT" ]; then
    # Run Wifite with the full Python interpreter path
    python "\$WIFITE_SCRIPT" "\$@"
else
    echo "ERROR: Wifite script not found!"
    echo "Expected location: \$WIFITE_SCRIPT"
    echo "Attempting to reinstall..."
    rm -rf ~/pentest-tools/src/wifite2
    mkdir -p ~/pentest-tools/src
    cd ~/pentest-tools/src
    git clone --depth=1 https://github.com/derv82/wifite2.git
    if [ -d ~/pentest-tools/src/wifite2 ]; then
        WIFITE_FOUND=\$(find ~/pentest-tools/src/wifite2 -type f -name "[Ww]ifite*.py" | head -n 1)
        if [ -n "\$WIFITE_FOUND" ]; then
            echo "Wifite reinstalled. Launching..."
            python "\$WIFITE_FOUND" "\$@"
        else
            echo "Failed to find Wifite script after reinstall."
            echo "Try running: sudo pacman -S aircrack-ng"
        fi
    else
        echo "Reinstallation failed. Please check your internet connection."
    fi
fi
EOL
        chmod +x ~/.local/bin/wifite
        
        echo "Wifite installation complete! Run 'wifite' to start."
    fi
    
    # Install Wifite from official packages as a fallback
    if [ -x /usr/bin/pacman ]; then
        echo "Installing Wifite from official package as fallback..."
        sudo pacman -S wifite --noconfirm 2>/dev/null || echo "Official wifite package not available, using source version."
    fi
    
    # Create simple standalone scripts for tools that couldn't be installed
    # This way, if the user installs them later, they'll work
    
    # Wifite helper script
    cat > ~/pentest-tools/bin/check-wifi-tools.sh << 'EOL'
#!/bin/bash
# Check for required wireless tools and provide installation instructions

echo "Checking wireless tool availability..."

# Define tools to check
tools=("aircrack-ng" "airodump-ng" "aireplay-ng" "hashcat" "reaver" "hcxdumptool" "hcxpcapngtool")

# Track missing tools
missing=()

echo "------------------------------------"
echo "WIRELESS TOOL STATUS"
echo "------------------------------------"

# Check each tool
for tool in "${tools[@]}"; do
    if command -v "$tool" &>/dev/null; then
        echo "[✓] $tool is installed"
    else
        echo "[✗] $tool is missing"
        missing+=("$tool")
    fi
done

echo "------------------------------------"

# Try to find wifite script
echo "Looking for Wifite script..."
if command -v wifite &>/dev/null; then
    echo "[✓] wifite launcher is available"
    wifite_path=$(which wifite)
    echo "    Path: $wifite_path"
else
    echo "[✗] wifite launcher is missing"
fi

WIFITE_SCRIPTS=(
    "/usr/bin/wifite"
    "$HOME/pentest-tools/src/wifite2/Wifite.py"
    "$HOME/pentest-tools/src/wifite2/wifite.py"
    "$HOME/pentest-tools/src/wifite2-install/Wifite.py"
    "$HOME/pentest-tools/src/wifite2-install/wifite.py"
)

for path in "${WIFITE_SCRIPTS[@]}"; do
    if [ -f "$path" ]; then
        echo "[✓] Found Wifite script at: $path"
        echo "    You can run it directly with: python $path"
    fi
done

# If tools are missing, provide installation instructions
if [ ${#missing[@]} -gt 0 ]; then
    echo ""
    echo "Some tools are missing. To install, run:"
    echo "sudo pacman -S aircrack-ng hashcat --noconfirm"
    
    echo ""
    echo "For Wifite to work best, you should install these missing tools."
    echo "See: https://github.com/derv82/wifite2#installation for more details"
fi

echo ""
echo "Wifite will work with whatever tools are available."
echo "Run 'wifite' to start wireless testing with available tools."

# Test if wifite actually works
echo ""
echo "Testing wifite..."
if command -v wifite &>/dev/null; then
    # Just test if it starts (then terminate)
    wifite --help | head -n 5 && echo "[✓] Wifite works correctly!"
else
    echo "[✗] Wifite not found in PATH."
    echo "Try running: python $HOME/pentest-tools/src/wifite2/Wifite.py"
fi
EOL
    chmod +x ~/pentest-tools/bin/check-wifi-tools.sh
    
    # Create launcher for wifite checker
    ln -sf ~/pentest-tools/bin/check-wifi-tools.sh ~/.local/bin/check-wifi-tools
    
    echo "Wireless tools installation complete!"
    echo "Run 'wifite' to start wireless testing."
    echo "Run 'check-wifi-tools' to verify tool installation status."
}

# Function to uninstall a package with error handling
uninstall_package() {
    echo "  --> Removing $1"
    if pacman -Q "$1" &>/dev/null; then
        # Check if we're having disk space issues directly from df instead of dmesg
        local free_space
        free_space=$(check_disk_space)
        if [ "$free_space" -lt 50 ]; then
            echo "WARNING: Low disk space detected (${free_space}MB). Cleaning up before continuing..."
            cleanup_disk_space
        fi
        
        # Try to remove the package
        sudo pacman -Rns "$1" --noconfirm 2> /tmp/pacman_error.log
        if [ $? -ne 0 ]; then
            # Check error output for disk space issues
            if grep -q "No space left on device" /tmp/pacman_error.log; then
                echo "WARNING: No space left on device. Cleaning up disk space..."
                cleanup_disk_space
                # Try again after cleanup
                sudo pacman -Rns "$1" --noconfirm || echo "WARNING: Failed to remove $1 even after cleanup, continuing..."
            else
                echo "WARNING: Failed to remove $1, continuing..."
            fi
        fi
    else
        echo "  --> Package $1 not installed, skipping..."
    fi
}

# Function to uninstall local installations
uninstall_local_tools() {
    echo "Removing locally installed tools..."
    
    # Remove tool directories first (frees space immediately)
    rm -rf ~/pentest-tools/src 2>/dev/null || true
    rm -rf ~/pentest-tools/collections 2>/dev/null || true
    
    # Remove path-related entries
    sed -i '/pentest-tools\/bin/d' ~/.bashrc 2>/dev/null || true
    sed -i '/\.local\/bin/d' ~/.bashrc 2>/dev/null || true
    sed -i '/LD_LIBRARY_PATH/d' ~/.bashrc 2>/dev/null || true
    
    # Clean user-installed Python packages
    if command -v pip &>/dev/null; then
        echo "Removing Python packages..."
        pip uninstall -y dnsrecon pwntools impacket crackmapexec 2>/dev/null || true
    fi
    
    # Now remove the rest
    rm -rf ~/.local/bin/* 2>/dev/null || true
    rm -rf ~/.local/share/pentest-tools 2>/dev/null || true
    rm -rf ~/pentest-tools 2>/dev/null || true
    rm -rf ~/.local/share/applications/pentest-tools.desktop 2>/dev/null || true
}

# Function to uninstall all penetration testing tools
uninstall_pentest_tools() {
    echo "Uninstalling penetration testing tools..."
    
    # Check free space first
    local free_space
    free_space=$(check_disk_space)
    echo "Current free disk space: ${free_space}MB"
    
    # If low on disk space, clean up first
    if [ "$free_space" -lt 100 ]; then
        echo "WARNING: Low disk space detected (${free_space}MB). Cleaning up first..."
        cleanup_disk_space
    fi
    
    # Check if local install was used - clean this first to free space
    if [ -d ~/pentest-tools ]; then
        echo "Local installation detected, removing local files..."
        uninstall_local_tools
    fi
    
    # Clean up pacman cache to make space
    echo "Clearing package cache to free space..."
    sudo pacman -Scc --noconfirm 2>/dev/null || true
    
    # Remove all installed core penetration testing tools
    echo "Removing core penetration testing tools..."
    CORE_TOOLS=("nmap" "hashcat" "john" "hydra" "metasploit")
    for tool in "${CORE_TOOLS[@]}"; do
        uninstall_package "$tool"
    done

    # Remove AUR packages first (more likely to free space)
    if command -v yay &>/dev/null; then
        echo "Removing AUR packages..."
        # This is a best-effort removal, not all packages may be installed
        for pkg in burpsuite crunch cewl-git python-certipy sherlock-git theharvester-git \
                   fierce-git bloodhound responder impacket feroxbuster enum4linux-ng \
                   subfinder amass brutespray sslyze sn1per crackmapexec wpscan ffuf; do
            if pacman -Q "$pkg" &>/dev/null; then
                echo "  --> Removing $pkg"
                sudo pacman -Rns "$pkg" --noconfirm 2> /tmp/pacman_error.log
                if [ $? -ne 0 ]; then
                    if grep -q "No space left on device" /tmp/pacman_error.log; then
                        cleanup_disk_space
                        sudo pacman -Rns "$pkg" --noconfirm || true
                    fi
                fi
            fi
        done
    fi
    
    # Remove system packages used by the installer
    echo "Removing system packages..."
    SYSTEM_PACKAGES=("git" "base-devel" "python-pip" "aircrack-ng" "wireless_tools" "iw")
    for tool in "${SYSTEM_PACKAGES[@]}"; do
        uninstall_package "$tool"
    done
    
    # Remove yay if installed
    if command -v yay &>/dev/null; then
        echo "Removing yay AUR helper..."
        sudo pacman -Rns yay-bin --noconfirm 2>/dev/null || true
        sudo pacman -Rns yay --noconfirm 2>/dev/null || true
    fi
    
    # Final cleanup
    echo "Performing final cleanup..."
    rm -f ~/.local/share/applications/pentest-tools.desktop 2>/dev/null || true
    rm -f ~/enable-readonly-mode.sh 2>/dev/null || true
    rm -f ~/restore_steamos.txt 2>/dev/null || true
    rm -f ~/clean-disk-space.sh 2>/dev/null || true
    rm -rf ~/.local/bin/check-pentest-tools 2>/dev/null || true
    
    # Final disk space cleanup
    cleanup_disk_space
    
    # Try to restore system snapshot if it exists
    if [ -d "/backup_before_pentest_tools" ]; then
        echo "System backup found. Do you want to restore it?"
        confirm "Type the confirmation code to restore system snapshot (this will revert all system changes):"
        
        echo "Restoring system from snapshot..."
        # Create a temporary backup of current state just in case
        sudo btrfs subvolume snapshot / /backup_before_restoration 2>/dev/null || true
        sudo mv /backup_before_pentest_tools /backup_for_restore
        sudo btrfs subvolume snapshot /backup_for_restore / 2>/dev/null || echo "WARNING: Failed to restore system snapshot."
    fi
    
    # Re-enable SteamOS read-only mode
    if command -v steamos-readonly &>/dev/null; then
        echo "Re-enabling SteamOS read-only mode..."
        sudo steamos-readonly enable || echo "WARNING: Failed to re-enable read-only mode."
    fi
    
    echo "Uninstallation complete. Some system changes may still remain."
    echo "For a complete restoration, consider using the SteamOS recovery functionality."
}

# Function for aggressive emergency cleanup of root partition
emergency_root_cleanup() {
    echo "EMERGENCY CLEANUP: Freeing space on root partition..."
    
    # Show current disk usage
    echo "Current partition usage:"
    df -h /
    
    # Clear pacman cache (most effective way to free space)
    echo "Clearing pacman cache..."
    sudo rm -rf /var/cache/pacman/pkg/* 2>/dev/null || true
    sudo pacman -Scc --noconfirm 2>/dev/null || true
    
    # Remove unnecessary cached packages
    echo "Removing orphaned packages..."
    sudo pacman -Rns $(pacman -Qtdq) --noconfirm 2>/dev/null || true
    
    # Clean system logs
    echo "Cleaning system logs..."
    sudo journalctl --vacuum-size=1M 2>/dev/null || true
    sudo find /var/log -type f -name "*.gz" -delete 2>/dev/null || true
    sudo find /var/log -type f -exec truncate -s 0 {} \; 2>/dev/null || true
    
    # Clear user caches
    echo "Cleaning user caches..."
    rm -rf ~/.cache/* 2>/dev/null || true
    
    # Clear temporary files
    echo "Clearing temporary files..."
    sudo find /tmp -type f -delete 2>/dev/null || true
    sudo find /var/tmp -type f -delete 2>/dev/null || true
    
    # Remove old kernel packages if any
    echo "Cleaning old kernels..."
    sudo paccache -rk1 2>/dev/null || true
    
    # Remove application caches
    echo "Cleaning application caches..."
    sudo rm -rf /var/cache/* 2>/dev/null || true
    
    # Remove core dumps
    sudo find /var/lib/systemd/coredump -type f -delete 2>/dev/null || true
    
    # Show new disk usage
    echo "New partition usage after cleanup:"
    df -h /
    
    # List largest directories on root partition for manual cleanup
    echo "Largest directories on root partition (in case you need to manually clean more):"
    sudo du -h -d 3 / 2>/dev/null | sort -hr | head -n 20
    
    free_space=$(check_disk_space)
    if [ "$free_space" -lt 50 ]; then
        echo "WARNING: Still very low on space (${free_space}MB). You may need to manually remove files."
        echo "Consider temporarily moving some large files from / to /home if needed."
    else
        echo "Cleanup successful! ${free_space}MB now available."
    fi
}

# Function to set up wrapper scripts for advanced tools
install_advanced_tools() {
    echo "Setting up wrapper scripts for advanced penetration testing tools..."
    
    # Create a directory for the wrapper scripts
    mkdir -p ~/pentest-tools/bin
    
    # Create wrapper script for hashcat
    cat > ~/pentest-tools/bin/hashcat-wrapper << 'EOF'
#!/bin/bash
if command -v hashcat >/dev/null 2>&1; then
    hashcat "$@"
else
    echo "Error: Hashcat is not installed!"
    echo "Install with: sudo pacman -S hashcat --noconfirm"
fi
EOF
    chmod +x ~/pentest-tools/bin/hashcat-wrapper
    
    # Create wrapper script for John the Ripper
    cat > ~/pentest-tools/bin/john-wrapper << 'EOF'
#!/bin/bash
if command -v john >/dev/null 2>&1; then
    john "$@"
else
    echo "Error: John the Ripper is not installed!"
    echo "Install with: sudo pacman -S john --noconfirm"
fi
EOF
    chmod +x ~/pentest-tools/bin/john-wrapper
    
    # Create wrapper script for Hydra
    cat > ~/pentest-tools/bin/hydra-wrapper << 'EOF'
#!/bin/bash
if command -v hydra >/dev/null 2>&1; then
    hydra "$@"
else
    echo "Error: Hydra is not installed!"
    echo "Install with: sudo pacman -S hydra --noconfirm"
fi
EOF
    chmod +x ~/pentest-tools/bin/hydra-wrapper
    
    # Create wrapper script for Metasploit
    cat > ~/pentest-tools/bin/metasploit-wrapper << 'EOF'
#!/bin/bash
if command -v msfconsole >/dev/null 2>&1; then
    msfconsole "$@"
else
    echo "Error: Metasploit is not installed!"
    echo "Install with: sudo pacman -S metasploit --noconfirm"
fi
EOF
    chmod +x ~/pentest-tools/bin/metasploit-wrapper
    
    # Create a check script to verify tool installation status
    cat > ~/pentest-tools/bin/check-pentest-tools << 'EOF'
#!/bin/bash
echo "===== Penetration Testing Tools Status ====="
echo ""

check_tool() {
    local tool=$1
    local package=$2
    if command -v $tool >/dev/null 2>&1; then
        echo "[✓] $tool is installed"
    else
        echo "[✗] $tool is NOT installed - Install with: sudo pacman -S $package --noconfirm"
    fi
}

# Check core tools
check_tool nmap nmap
check_tool hashcat hashcat
check_tool john john
check_tool hydra hydra
check_tool msfconsole metasploit

echo ""
echo "Tool directory: ~/pentest-tools"
echo "Wrapper scripts directory: ~/pentest-tools/bin"
echo ""
EOF
    chmod +x ~/pentest-tools/bin/check-pentest-tools
    
    # Create symlinks in ~/.local/bin for easy access
    mkdir -p ~/.local/bin
    ln -sf ~/pentest-tools/bin/check-pentest-tools ~/.local/bin/
    
    echo "Advanced tools setup complete."
    echo "Run 'check-pentest-tools' to verify tool installations."
}

# Function to set up Python environment
setup_python_env() {
    echo "Setting up Python virtual environment..."
    
    # Create virtual environment using the built-in venv module
    mkdir -p ~/pentest-tools/venv
    python -m venv ~/pentest-tools/venv || {
        echo "WARNING: Failed to create virtual environment with venv."
        echo "Trying alternative approach..."
        
        # Try to create directory structure manually as fallback
        mkdir -p ~/pentest-tools/venv/bin
        mkdir -p ~/pentest-tools/venv/lib
        
        # Create a simple activation script as fallback
        cat > ~/pentest-tools/venv/bin/activate << 'EOL'
#!/bin/bash
# Simple activation script
export PATH="$HOME/pentest-tools/bin:$PATH"
export PYTHONPATH="$HOME/pentest-tools/lib:$PYTHONPATH"
echo "Basic environment activated."
EOL
        chmod +x ~/pentest-tools/venv/bin/activate
        
        echo "Created basic environment structure."
    }
    
    # Create activation script
    cat > ~/pentest-tools/bin/activate-python << 'EOL'
#!/bin/bash
# Activate Python virtual environment
if [ -f ~/pentest-tools/venv/bin/activate ]; then
    source ~/pentest-tools/venv/bin/activate
    echo "Python virtual environment activated."
else
    echo "WARNING: Virtual environment not found."
fi
EOL
    chmod +x ~/pentest-tools/bin/activate-python
    
    # Create a direct pip install wrapper that uses --break-system-packages
    cat > ~/pentest-tools/bin/pentest-pip << 'EOL'
#!/bin/bash
# Special pip wrapper for SteamOS
if [ -f ~/pentest-tools/venv/bin/pip ]; then
    # Use virtual environment pip if available
    ~/pentest-tools/venv/bin/pip "$@"
else
    # Fallback: Use system pip with override flag
    python -m pip "$@" --break-system-packages --user
fi
EOL
    chmod +x ~/pentest-tools/bin/pentest-pip
    ensure_command_in_path "pentest-pip" "$HOME/pentest-tools/bin/pentest-pip"
    
    # Try to activate the environment
    if [ -f ~/pentest-tools/venv/bin/activate ]; then
        source ~/pentest-tools/venv/bin/activate
        echo "Using Python: $(which python)"
    else
        echo "WARNING: Will use system Python with --break-system-packages flag"
    fi
    
    return 0
}

# Function to install core penetration testing tools directly via pacman
install_core_tools() {
    echo "Installing core penetration testing tools..."
    
    # Define core tools to install
    core_tools=("nmap" "hashcat" "john" "hydra" "metasploit")
    
    # Install each tool
    for tool in "${core_tools[@]}"; do
        echo "Installing $tool..."
        if sudo pacman -S "$tool" --noconfirm; then
            echo "✓ $tool installed successfully"
        else
            echo "✗ Failed to install $tool"
        fi
    done
    
    echo "Core penetration testing tools installation complete"
    echo "You can verify installations with 'check-pentest-tools'"
}

# Function to check if pacman is available
check_pacman() {
    if ! command -v pacman >/dev/null 2>&1; then
        echo "ERROR: pacman package manager not found. This script requires Arch Linux or SteamOS."
        exit 1
    fi
    
    # Check if we can run pacman commands
    if ! pacman -V >/dev/null 2>&1; then
        echo "ERROR: Unable to run pacman. Ensure you have appropriate permissions."
        exit 1
    fi
    
    echo "Pacman package manager detected."
}

# Function to display header information
display_header() {
    echo "======================================================"
    echo "REDD's SteamOS Steam Deck Penetration Testing Tools"
    echo "======================================================"
    echo "This script will install/uninstall penetration testing tools"
    echo "on your SteamOS/Steam Deck system."
    echo ""
    
    if [ "$UNINSTALL" = true ]; then
        echo "OPERATION: UNINSTALL"
    else
        echo "OPERATION: INSTALL"
        if [ "$LOCAL_INSTALL" = true ]; then
            echo "INSTALL MODE: LOCAL (Home Directory Installation)"
        else
            echo "INSTALL MODE: SYSTEM (System-wide Installation)"
        fi
    fi
    echo "======================================================"
    echo ""
}

# Function to create a system snapshot before making changes
create_system_snapshot() {
    echo "Attempting to create a system snapshot before making changes..."
    
    # First check if we're on SteamOS and if btrfs is available
    if grep -q "SteamOS" /etc/os-release && command -v btrfs >/dev/null 2>&1; then
        # Try to create a btrfs snapshot
        echo "Attempting to create a BTRFS snapshot..."
        if sudo btrfs subvolume snapshot / /backup_before_pentest_tools 2>/dev/null; then
            echo "System snapshot created successfully at /backup_before_pentest_tools"
            echo "To restore, you can run: sudo btrfs subvolume snapshot /backup_before_pentest_tools /"
            
            # Create a simple restoration instruction file
            cat > ~/restore_steamos.txt << 'EOL'
# Restoration instructions for SteamOS after penetration testing tools installation

If you need to restore your system to the state before installing penetration testing tools,
you can use one of the following methods:

1. Use the snapshot created by the installation script:
   sudo btrfs subvolume snapshot /backup_before_pentest_tools /

2. Use the SteamOS recovery options:
   - Hold power button to reboot
   - Select "Boot Options" from the boot menu
   - Choose "SteamOS Recovery"

3. Run the script with the --uninstall flag:
   bash rpt.sh --uninstall

For more information, consult the SteamOS documentation.
EOL
            echo "Restoration instructions saved to ~/restore_steamos.txt"
        else
            echo "WARNING: Could not create system snapshot. Continuing without backup."
            echo "If you encounter issues, you may need to use SteamOS recovery options."
        fi
    else
        echo "NOTE: System snapshot feature not available on this system."
        echo "Continuing without creating a backup."
    fi
    
    # Create a disk cleanup script for emergency use
    cat > ~/clean-disk-space.sh << 'EOL'
#!/bin/bash
# Emergency script to clean up disk space

echo "Emergency disk space cleanup in progress..."

# Clear pacman cache
sudo rm -rf /var/cache/pacman/pkg/* 2>/dev/null || true
sudo pacman -Scc --noconfirm 2>/dev/null || true

# Remove logs
sudo journalctl --vacuum-time=1d 2>/dev/null || true
sudo find /var/log -name "*.gz" -delete 2>/dev/null || true
sudo find /var/log -type f -exec truncate -s 0 {} \; 2>/dev/null || true

# Clean temporary files
sudo rm -rf /tmp/* /var/tmp/* 2>/dev/null || true

# Clean user cache
rm -rf ~/.cache/* 2>/dev/null || true

# Display results
df -h / /home

echo "Cleanup complete. Use 'du -h -d 2 /' to find more large directories."
EOL
    chmod +x ~/clean-disk-space.sh
    echo "Created emergency disk cleanup script at ~/clean-disk-space.sh"
}

# Function to create necessary directories
create_directories() {
    mkdir -p ~/pentest-tools/bin
    mkdir -p ~/pentest-tools/src
    mkdir -p ~/.local/bin
    echo "Created necessary directories"
}

# Function to check available disk space on root and home partitions
check_disk_space_full() {
    # Check root partition
    ROOT_FREE_SPACE=$(df -m / | awk 'NR==2 {print $4}')
    echo "Free space on root partition: ${ROOT_FREE_SPACE}MB"
    
    # Check home partition
    HOME_FREE_SPACE=$(df -m /home | awk 'NR==2 {print $4}')
    echo "Free space on home partition: ${HOME_FREE_SPACE}MB"
    
    # Warn if root partition is low
    if [ "$ROOT_FREE_SPACE" -lt 500 ]; then
        echo "WARNING: Low disk space on root partition (${ROOT_FREE_SPACE}MB)."
        echo "Consider using --local mode to install to home directory."
    fi
    
    # Warn if home partition is low
    if [ "$HOME_FREE_SPACE" -lt 1000 ]; then
        echo "WARNING: Low disk space on home partition (${HOME_FREE_SPACE}MB)."
        echo "You may not have enough space for all tools."
    fi
}

# Function to prompt the user for a yes/no answer
prompt_user() {
    local prompt="$1"
    local response
    
    echo -n "$prompt [y/N] "
    read -r response
    
    case "$response" in
        [yY][eE][sS]|[yY]) 
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

# Function to set up AUR helper (yay)
setup_aur() {
    echo "Setting up AUR helper (yay)..."
    
    # Check if yay is already installed
    if command -v yay >/dev/null 2>&1; then
        echo "AUR helper (yay) already installed."
        return 0
    fi
    
    # Install git if not already installed
    if ! command -v git >/dev/null 2>&1; then
        echo "Installing git..."
        sudo pacman -S git --noconfirm || {
            echo "ERROR: Failed to install git. Cannot continue with AUR setup."
            return 1
        }
    fi
    
    # Install base-devel if not already installed
    sudo pacman -S base-devel --noconfirm || {
        echo "WARNING: Could not install base-devel. Some AUR packages might fail to build."
    }
    
    # Create temporary directory for yay installation
    mkdir -p ~/pentest-tools/src
    cd ~/pentest-tools/src || return 1
    
    # Clone yay repository
    echo "Cloning yay repository..."
    git clone https://aur.archlinux.org/yay-bin.git || {
        echo "ERROR: Failed to clone yay repository."
        return 1
    }
    
    # Build and install yay
    cd yay-bin || return 1
    echo "Building and installing yay..."
    makepkg -si --noconfirm || {
        echo "ERROR: Failed to build and install yay."
        return 1
    }
    
    cd ~ || return 1
    echo "AUR helper (yay) installed successfully."
    return 0
}

# Function to install other tools via pacman and AUR
install_other_tools() {
    echo "Installing additional penetration testing tools..."
    
    # Install network scanning tools
    echo "Installing network scanning tools..."
    install_pacman_package "nmap"
    install_pacman_package "netcat"
    install_pacman_package "wireshark-cli"
    
    # Install web testing tools
    echo "Installing web testing tools..."
    install_pacman_package "sqlmap"
    
    # Install password cracking tools
    echo "Installing password cracking tools..."
    install_pacman_package "hashcat"
    install_pacman_package "john"
    
    # Install exploitation tools
    echo "Installing exploitation tools..."
    install_pacman_package "metasploit"
    
    echo "Additional tool installation complete."
}

# Function to install local tools (non-system packages)
install_local_tools() {
    echo "Installing local tools to home directory..."
    
    # Install Python tools
    install_python_tools
    
    # Install wireless tools
    install_wireless_tools
    
    # Clone security tools collections
    clone_security_tools
    
    echo "Local tool installation complete."
}

# Function to set up aliases for easy access
setup_aliases() {
    echo "Setting up aliases for easy access..."
    
    # Check if .bashrc exists
    if [ -f ~/.bashrc ]; then
        # Add aliases to .bashrc if they don't already exist
        if ! grep -q "alias pentest-tools" ~/.bashrc; then
            cat >> ~/.bashrc << 'EOL'

# Penetration testing tools aliases
alias pentest-tools='cd ~/pentest-tools'
alias check-tools='check-pentest-tools'
alias clean-space='~/clean-disk-space.sh'
EOL
            echo "Aliases added to ~/.bashrc"
        else
            echo "Aliases already exist in ~/.bashrc"
        fi
    fi
    
    # Create aliases file that can be sourced
    cat > ~/pentest-aliases.sh << 'EOL'
#!/bin/bash
# Penetration testing tools aliases
alias pentest-tools='cd ~/pentest-tools'
alias check-tools='check-pentest-tools'
alias clean-space='~/clean-disk-space.sh'

echo "Penetration testing aliases loaded."
echo "Use 'check-tools' to verify your tools."
EOL
    chmod +x ~/pentest-aliases.sh
    
    echo "Aliases setup complete. Source with: source ~/pentest-aliases.sh"
}

# Function to create symlinks for all installed tools
create_tool_symlinks() {
    echo "Setting up command symlinks..."
    
    # Create metasploit symlinks
    if command -v msfconsole >/dev/null 2>&1; then
        echo "Creating metasploit symlinks..."
        ln -sf $(which msfconsole) ~/.local/bin/metasploit 2>/dev/null || true
        ln -sf $(which msfconsole) ~/.local/bin/msf 2>/dev/null || true
    elif [ -f /usr/bin/msfconsole ]; then
        ln -sf /usr/bin/msfconsole ~/.local/bin/metasploit 2>/dev/null || true
        ln -sf /usr/bin/msfconsole ~/.local/bin/msf 2>/dev/null || true
    fi
    
    # Create symlinks for core tools to ensure they're in PATH
    local tools=("nmap" "hashcat" "john" "hydra" "sqlmap" "wifite" "msfconsole")
    for tool in "${tools[@]}"; do
        if command -v "$tool" >/dev/null 2>&1; then
            echo "Creating symlink for $tool..."
            ln -sf $(which "$tool") ~/.local/bin/"$tool" 2>/dev/null || true
        fi
    done
    
    # Fix specific tool symlinks if they exist in standard locations
    # Metasploit
    [ -f /opt/metasploit-framework/msfconsole ] && ln -sf /opt/metasploit-framework/msfconsole ~/.local/bin/msfconsole
    [ -f /usr/share/metasploit-framework/msfconsole ] && ln -sf /usr/share/metasploit-framework/msfconsole ~/.local/bin/msfconsole
    
    # Make sure wifite is in PATH
    if [ -f "$HOME/pentest-tools/src/wifite2/Wifite.py" ]; then
        echo "Creating wifite symlink..."
        cat > ~/.local/bin/wifite << 'EOL'
#!/bin/bash
python "$HOME/pentest-tools/src/wifite2/Wifite.py" "$@"
EOL
        chmod +x ~/.local/bin/wifite
    fi
    
    # Try to find wifite in other potential locations
    for wifite_path in $(find ~/pentest-tools -name "Wifite.py" -o -name "wifite.py" 2>/dev/null); do
        echo "Found wifite at $wifite_path, creating symlink..."
        cat > ~/.local/bin/wifite << EOL
#!/bin/bash
python "$wifite_path" "\$@"
EOL
        chmod +x ~/.local/bin/wifite
        break
    done
    
    echo "Symlinks created in ~/.local/bin"
}

# Function to finalize installation
finalize_installation() {
    echo "Finalizing installation..."
    
    # Create symlinks for all tools
    create_tool_symlinks
    
    # Update shell configuration
    echo "Updating shell configuration..."
    
    # Create a setup script to be sourced at the end
    cat > ~/use-pentest-tools.sh << 'EOL'
#!/bin/bash
# This script sets up the environment for penetration testing tools

# Add the pentest tools to the PATH
export PATH="$HOME/.local/bin:$HOME/pentest-tools/bin:$PATH"
export LD_LIBRARY_PATH="$HOME/.local/lib:$LD_LIBRARY_PATH"

# Set up aliases
alias msf='metasploit'
alias msfconsole='metasploit'
alias pentest-tools='cd ~/pentest-tools'
alias check-tools='check-pentest-tools'

echo "Penetration testing tools are now ready to use!"
echo "Run 'check-pentest-tools' to verify your installation."
EOL
    chmod +x ~/use-pentest-tools.sh
    
    # Source the setup script
    source ~/use-pentest-tools.sh
    
    echo "===================================================="
    echo "INSTALLATION COMPLETE!"
    echo "===================================================="
    echo "To use your tools, run:"
    echo "  source ~/use-pentest-tools.sh"
    echo ""
    echo "Or restart your terminal."
    echo ""
    echo "You can verify your installation with:"
    echo "  check-pentest-tools"
    echo "===================================================="
}

# Main script execution flow function
run_installation() {
    # Check disk space before proceeding
    check_disk_space_full
    
    # Only run the emergency cleanup if needed
    if [ "${ROOT_FREE_SPACE:-0}" -lt 250 ]; then
        if prompt_user "WARNING: Low disk space on root partition (${ROOT_FREE_SPACE:-0} MB). Run emergency cleanup?"; then
            emergency_root_cleanup
        fi
    fi
    
    # Set up AUR helper
    setup_aur
    
    # Install all tools
    install_core_tools
    install_other_tools
    install_advanced_tools
    
    if [ "$LOCAL_INSTALL" = true ]; then
        install_local_tools
    fi
    
    # Create useful alias for easy access
    setup_aliases
    
    # Finalize the installation
    finalize_installation
    
    echo "Installation Script Complete."
    echo "Run 'source ~/use-pentest-tools.sh' to start using your tools immediately."
}

# Main script execution
parse_arguments "$@"
display_header

# Check if we're in uninstall mode
if [ "$UNINSTALL" = true ]; then
    # Only basic checks needed for uninstallation
    check_pacman
    uninstall_pentest_tools
    exit 0
fi

# Full installation flow
check_steamos
check_pacman

# Create a system snapshot before making changes
create_system_snapshot

# Create necessary directories
create_directories

# Set up local installation directories if needed
if [ "$LOCAL_INSTALL" = true ]; then
    setup_local_dirs
fi

# Run the main installation process
run_installation
