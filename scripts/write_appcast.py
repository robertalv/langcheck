#!/usr/bin/env python3
import argparse
import email.utils
import hashlib
import os
from pathlib import Path
from xml.sax.saxutils import escape


def main() -> None:
    parser = argparse.ArgumentParser(description="Write a Sparkle appcast for one DMG release.")
    parser.add_argument("--version", required=True)
    parser.add_argument("--build", required=True)
    parser.add_argument("--dmg", required=True)
    parser.add_argument("--download-url", required=True)
    parser.add_argument("--ed-signature", default="")
    parser.add_argument("--minimum-system-version", default="14.0")
    parser.add_argument("--output", required=True)
    args = parser.parse_args()

    dmg = Path(args.dmg)
    length = dmg.stat().st_size
    sha256 = hashlib.sha256(dmg.read_bytes()).hexdigest()
    pub_date = email.utils.formatdate(localtime=False, usegmt=True)

    signature_attr = f' sparkle:edSignature="{escape(args.ed_signature)}"' if args.ed_signature else ""
    notes = f"""
        <h2>LangCheck {escape(args.version)}</h2>
        <p>Download and install this build to get the latest LangCheck analysis and AI chat improvements.</p>
        <p>SHA-256: <code>{sha256}</code></p>
    """

    xml = f"""<?xml version="1.0" encoding="UTF-8"?>
<rss version="2.0"
     xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"
     xmlns:dc="http://purl.org/dc/elements/1.1/">
  <channel>
    <title>LangCheck Updates</title>
    <description>Latest LangCheck macOS releases</description>
    <language>en</language>
    <item>
      <title>LangCheck {escape(args.version)}</title>
      <description><![CDATA[
{notes}
      ]]></description>
      <pubDate>{pub_date}</pubDate>
      <sparkle:version>{escape(args.build)}</sparkle:version>
      <sparkle:shortVersionString>{escape(args.version)}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>{escape(args.minimum_system_version)}</sparkle:minimumSystemVersion>
      <enclosure
        url="{escape(args.download_url)}"
        sparkle:version="{escape(args.build)}"
        sparkle:shortVersionString="{escape(args.version)}"
        length="{length}"
        type="application/octet-stream"{signature_attr} />
    </item>
  </channel>
</rss>
"""

    output = Path(args.output)
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(xml, encoding="utf-8")
    print(f"Wrote {output}")


if __name__ == "__main__":
    main()
