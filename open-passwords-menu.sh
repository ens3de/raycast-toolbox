#!/bin/bash

# @raycast.schemaVersion 1
# @raycast.title 打开密码菜单
# @raycast.mode silent
# @raycast.icon 🔑
# @raycast.packageName Passwords

exec "$(dirname "$0")/passwords-menu/open-passwords-menu"
