#!/bin/bash
# REDD's SteamOS Steam Deck Pentest Tools Installer
#
# This script unlocks the typicial Arch Linux installer enviroment (pacman/yay). - While 
# installing a few pentest tools to get the collection started.
# 
# Enjoy!



# Disable SteamOS read-only mode (if applicable)
sudo steamos-readonly disable

# Initialize the pacman keyring
sudo pacman-key --init

# Populate the Arch Linux and holo keyrings
sudo pacman-key --populate archlinux
sudo pacman-key --populate holo

# Update pacman database and upgrade the system
sudo pacman -Syu --noconfirm

# Install desired packages
sudo pacman -S wifite john hcxtools hcxdumptool hashcat metasploit \
routersploit reaver cowpatty postgresql python hydra wireshark tcpdump \
base-devel --noconfirm

# Note: For packages like burpsuite which may not be available directly via pacman,
# you could consider installing from AUR or alternative methods. Example using yay (AUR helper):
# yay -S burpsuite --noconfirm

# Setup METASPLOIT
sudo msfdb init

# All Done
echo "Installation Script Complete."
