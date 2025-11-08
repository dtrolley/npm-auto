# 🧩 npm-auto  
**Automated Reverse Proxy Host Management for Unraid + Nginx Proxy Manager**

![Unraid](https://img.shields.io/badge/Unraid-Plugin-ff6600?logo=unraid&logoColor=white)
![Version](https://img.shields.io/github/v/release/dtrolley/npm-auto)
![License](https://img.shields.io/github/license/dtrolley/npm-auto)
![Build](https://img.shields.io/github/actions/workflow/status/dtrolley/npm-auto/release.yml?label=Build)
![Maintainer](https://img.shields.io/badge/maintainer-dTrolley-blue)

---

### 🚀 Overview
**npm-auto** is a lightweight Unraid plugin that automatically manages reverse proxy entries in your running Nginx Proxy Manager (NPM) instance.  
When enabled, it watches your Docker containers and syncs them with NPM via the official API schema — creating, updating, or removing proxy hosts automatically as containers start and stop.

---

### ⚙️ Features
- Adds a new **toggle column** to the Unraid Docker tab to mark containers for NPM automation  
- Creates or removes reverse proxy hosts based on container lifecycle  
- Configurable via the **Unraid Settings tab**  
- Uses NPM’s **official API schema** (no CLI hacks)  
- Respects existing SSL certificates in NPM  
- Optional **container label overrides** for custom hostnames, ports, or IPs  
- Persistent state between reboots  

---

### 🧰 Settings
From the Unraid **Settings → npm-auto** page:
- Toggle to enable/disable the plugin  
- NPM host IP and port  
- NPM credentials (username/password)  
- Default domain for proxy hosts  
- Connectivity status check  
- Option to enable container label overrides  

---

### 📦 Installation

Copy and paste this URL into your **Unraid WebGUI → Plugins → Install Plugin** field:

