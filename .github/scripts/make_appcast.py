#!/usr/bin/env python3
import argparse
from datetime import datetime, timezone
from pathlib import Path


TEMPLATE = """<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Q*Й</title>
    <link>https://github.com/graninilya/keyswitcher</link>
    <description>Auto-updates for Q*Й.</description>
    <language>ru</language>
    <item>
      <title>v{version}</title>
      <pubDate>{pubdate}</pubDate>
{description_block}      <enclosure
        url="https://github.com/graninilya/keyswitcher/releases/download/v{version}/QY-{version}.dmg"
        sparkle:version="{build}"
        sparkle:shortVersionString="{version}"
        type="application/octet-stream"
        {sig_attrs} />
      <sparkle:minimumSystemVersion>13.0</sparkle:minimumSystemVersion>
    </item>
  </channel>
</rss>
"""


def build_description_block(notes_path: str | None) -> str:
    if not notes_path:
        return ""
    html = Path(notes_path).read_text(encoding="utf-8").strip()
    if not html:
        return ""
    return f"      <description><![CDATA[\n{html}\n      ]]></description>\n"


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--version", required=True)
    p.add_argument("--build", required=True)
    p.add_argument("--sig-attrs", default='length="0"')
    p.add_argument("--notes-html",
                   help="Path to HTML file with release notes shown in Sparkle's update prompt")
    p.add_argument("--output", required=True)
    args = p.parse_args()

    pubdate = datetime.now(timezone.utc).strftime("%a, %d %b %Y %H:%M:%S +0000")
    out = TEMPLATE.format(
        version=args.version,
        build=args.build,
        pubdate=pubdate,
        sig_attrs=args.sig_attrs.strip(),
        description_block=build_description_block(args.notes_html),
    )
    Path(args.output).write_text(out, encoding="utf-8")
    print(f"→ {args.output}")


if __name__ == "__main__":
    main()
