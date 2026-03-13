#!/usr/bin/env python3
"""
Test script for rss-heartbeat-skill handler
Simulates how main agent would call the skill
"""

import os
import sys
import json
import subprocess
from pathlib import Path

# Add skills path
sys.path.insert(0, '/Users/franklin/.openclaw/workspace/skills/rss-heartbeat-skill')

# Import the handler
from handler import handle_system_event

# Simulate context with message tool
def mock_message_tool(**kwargs):
    """Mock message tool that just prints"""
    print(f"[MOCK] Sending message: {kwargs.get('message', '')[:100]}...")
    return {'result': {'messageId': 'mock-123'}}

# Test context
context = {
    'tools': {
        'message': mock_message_tool
    },
    'user_id': 'ou_4bec49d80141982d31d1f1f67c943de7',
    'RSS_DATA_DIR': '/Users/franklin/.openclaw/workspace/rss-data',
    'RSS_FETCH_SCRIPT': '/Users/franklin/.openclaw/workspace/skills/rss-fetch-skill/fetch-rss.py'
}

# Simulate system event
event = {
    'text': '{"action": "rss_check"}'
}

print("Testing rss-heartbeat-skill handler...")
print("=" * 60)

result = handle_system_event(event, context)

print("=" * 60)
print("Result:")
print(json.dumps(result, ensure_ascii=False, indent=2))