#!/usr/bin/env python3
"""
Генерирует appcast.xml для Sparkle на основе новой версии и DMG.
"""
import argparse
import os
from datetime import datetime, timezone
from pathlib import Path


TEMPLATE = """<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Q*Й</title>
    <link>https://github.com/graninilya/keyswitcher</items>
    <description>Auto-updates for Q*Й.</description>
    <language>ru</language>
    <item>
      <title>v{version}</title>
      <pubDate>{pubdate}</pubDate>
      <enclosure
        url="https://github.com/graninilya/keyswitcher/releases/download/v{version}/QY-{version}.dmg"
        sparkle:version="{build}"
        sparkle:shortVersionString="{version}"
        sparkle:edSignature="{signature}"
        length="{length}"
        type="application/octet-stream" />
      <sparkle:minimumSystemVersion>13.0</sparkle:minimumSystemVersion>
    </item>
  </channel>
</rss>
"""


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--version", required=True)
    p.add_argument("--build", required=True)
    p.add_argument("--dmg", required=True)
    p.add_argument("--signature", default="")
    p.add_argument("--output", required=True)
    args = p.parse_args()

    dmg = Path(args.dmg)
    if not dmg.exists():
        raise SystemExit(f"DMG not found: {dmg}")
    length = dmg.stat().st_size
    pubdate = datetime.now(timezone.utc).strftime("%a, %d %b %Y %H:%M:%S +0000")

    out = TEMPLATE.format(
        version=args.version,
        build=args.build,
        pubdate=pubdate,
        signature=args.signature,
        length=length,
    )
    Path(args.output).write_text(out, encoding="utf-8")
    print(f"→ {args.output}")


if __name__ == "__main__":
    main()
