#!/bin/bash

# Ensure the script is run with sudo privilege
if [ "$EUID" -ne 0 ]; then
  echo "Please run this script as root or with sudo."
  exit 1
fi

echo "Updating package lists..."
apt-get update -y > /dev/null 2>&1

# ==========================================
# 1. CHECK & INSTALL SSH
# ==========================================
echo -e "\nChecking SSH status..."
if dpkg -s openssh-client openssh-server > /dev/null 2>&1; then
    echo " SSH is already installed."
else
    echo "  SSH is missing. Installing OpenSSH..."
    apt-get install -y openssh-client openssh-server
    systemctl enable --now ssh
    echo " SSH installed and service started successfully."
fi

# ==========================================
# 2. CHECK & INSTALL ANSIBLE
# ==========================================
echo -e "\nChecking Ansible status..."
if command -v ansible > /dev/null 2>&1; then
    echo " Ansible is already installed. ($(ansible --version | head -n 1))"
else
    echo "  Ansible is missing. Installing..."
    apt-get install -y software-properties-common
    add-apt-repository --yes --update ppa:ansible/ansible
    apt-get install -y ansible
    
    echo " Ansible installed successfully. ($(ansible --version | head -n 1))"
fi

echo -e "\nComplete!"

