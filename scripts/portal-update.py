#!/usr/bin/env python3
# portal-update.py
# Posts a build update to the AXRIK client portal (Supabase)
# Usage: python3 portal-update.py "Your message here" build

import sys
import json
import urllib.request

SUPABASE_URL = "https://udwnvezlxdscpvsyuyhe.supabase.co"
SUPABASE_KEY = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InVkd252ZXpseGRzY3B2c3l1eWhlIiwicm9sZSI6InNlcnZpY2Vfcm9sZSIsImlhdCI6MTc4MDMzMzI3NiwiZXhwIjoyMDk1OTA5Mjc2fQ.rWjRDKDwI5A-hKiMmgJ-z06PdLsbwoFbw0VVcpPuN0c"
PROJECT_ID   = "36edaf0b-c8b2-4ba4-985e-c32891b5c1f1"

message = sys.argv[1] if len(sys.argv) > 1 else None
stage   = sys.argv[2] if len(sys.argv) > 2 else "build"

if not message:
    print("Usage: python3 portal-update.py \"Your message\" build")
    sys.exit(1)

payload = json.dumps({
    "project_id":    PROJECT_ID,
    "message":       message,
    "stage_at_time": stage,
    "posted_by":     "67e7cc7f-b4b1-4f1e-a8a3-0df78cd8ec60",
}).encode("utf-8")

req = urllib.request.Request(
    f"{SUPABASE_URL}/rest/v1/project_updates",
    data    = payload,
    method  = "POST",
    headers = {
        "apikey":        SUPABASE_KEY,
        "Authorization": f"Bearer {SUPABASE_KEY}",
        "Content-Type":  "application/json",
        "Prefer":        "return=minimal"
    }
)

try:
    with urllib.request.urlopen(req) as res:
        print(f"✅ Portal updated successfully (HTTP {res.status})")
except urllib.error.HTTPError as e:
    body = e.read().decode()
    print(f"❌ Portal update failed: HTTP {e.code} — {body}")
    sys.exit(1)
except Exception as e:
    print(f"❌ Error: {e}")
    sys.exit(1)
