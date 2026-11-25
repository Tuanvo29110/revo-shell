#!/bin/bash
# Reads notification counts from window titles using hyprctl
# Output format: appId|count per line
# Apps like Discord put "(1)" or "[2]" in their window title

hyprctl clients -j 2>/dev/null | python3 -c "
import sys, json, re

try:
    clients = json.load(sys.stdin)
except:
    sys.exit(0)

for c in clients:
    title = c.get('title', '')
    class_name = c.get('class', '')
    initial_title = c.get('initialTitle', '')
    
    # only a bracketed number is a badge: (3), [12], (99+), (17,761).
    # Bare numbers (issue #583, line 40, dates) are just part of the title.
    m = re.search(r'[\(\[](\d+(?:,\d{3})*)\+?[\)\]]', title)
    count = int(m.group(1).replace(',', '')) if m else 0
    
    if count > 0:
        print(f'{class_name}|{count}')
" 2>/dev/null
