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
echo "  --> Installing Wifite"
sudo pacman -S wifite --noconfirm
echo "  --> Installing John the Ripper"
sudo pacman -S john --noconfirm
echo "  --> Installing hcxtools"
sudo pacman -S hcxtools --noconfirm
echo "  --> Installing hcxdumptool"
sudo pacman -S hcxdumptool --noconfirm
echo "  --> Installing hashcat"
sudo pacman -S hashcat --noconfirm
echo "  --> Installing Metasploit"
sudo pacman -S metasploit --noconfirm
echo "  --> Installing Routersploit"
sudo pacman -S routersploit --noconfirm
echo "  --> Installing Reaver"
sudo pacman -S reaver --noconfirm
echo "  --> Installing cowpatty"
sudo pacman -S cowpatty --noconfirm
echo "  --> Installing PostgreSQL"
sudo pacman -S postgresql --noconfirm
echo "  --> Installing Hydra"
sudo pacman -S hydra --noconfirm
echo "  --> Installing wireshark"
sudo pacman -S wireshark --noconfirm
echo "  --> Installing tcpdump"
sudo pacman -S tcpdump --noconfirm
echo "  --> Installing base-devel tools"
sudo pacman -S base-devel --noconfirm
echo "  --> Installing aircrack-ng"
sudo pacman -S aircrack-ng --noconfirm

# AUR Packages
echo "  --> Attempting to install Burpsuite" 
yay -S burpsuite --noconfirm

# Setup METASPLOIT
echo "  --> Setting Up Metasploit"
sudo msfdb init

# All Done
echo "Installation Script Complete."
