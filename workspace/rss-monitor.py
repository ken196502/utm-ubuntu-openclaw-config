#!/usr/bin/env python3
"""
RSS Monitor - Fetches RSS feed and reports latest article node (no latest.md)
"""

import os
import sys
import json
import argparse
import datetime
import subprocess
from pathlib import Path

import requests
import xml.etree.ElementTree as ET

# Try to import html2text
try:
    import html2text
    HAS_HTML2TEXT = True
except ImportError:
    HAS_HTML2TEXT = False


def fetch_rss_xml(rss_url: str, output_path: Path):
    """Fetch RSS feed and save XML (overwrite)."""
    headers = {'User-Agent': 'Mozilla/5.0 (compatible; RSSBot/1.0)'}
    resp = requests.get(rss_url, headers=headers, timeout=30)
    resp.raise_for_status()
    output_path.write_bytes(resp.content)
    return resp.content


def parse_feed(xml_content: bytes) -> list:
    """Parse RSS feed and return items."""
    root = ET.fromstring(xml_content)
    items = []

    if root.tag.endswith('rss'):
        channel = root.find('channel')
        if channel is None:
            return items
        for item in channel.findall('item'):
            title_elem = item.find('title')
            link_elem = item.find('link')
            pubDate_elem = item.find('pubDate')

            if title_elem is None or link_elem is None:
                continue

            pub_date = None
            if pubDate_elem is not None and pubDate_elem.text:
                try:
                    pub_date = datetime.datetime.strptime(
                        pubDate_elem.text.strip(),
                        '%a, %d %b %Y %H:%M:%S %z'
                    )
                    pub_date = pub_date.replace(tzinfo=None)
                except Exception:
                    pub_date = None

            items.append({
                'title': (title_elem.text or '').strip(),
                'url': (link_elem.text or '').strip(),
                'published': pub_date,
            })
    else:  # Atom
        for entry in root.findall('{http://www.w3.org/2005/Atom}entry'):
            title_elem = entry.find('{http://www.w3.org/2005/Atom}title')
            link_elem = entry.find('{http://www.w3.org/2005/Atom}link')
            published_elem = entry.find('{http://www.w3.org/2005/Atom}published')

            if title_elem is None or link_elem is None:
                continue

            url = link_elem.get('href', '')
            pub_date = None
            if published_elem is not None and published_elem.text:
                try:
                    pub_date = datetime.datetime.fromisoformat(
                        published_elem.text.replace('Z', '+00:00')
                    )
                    pub_date = pub_date.replace(tzinfo=None)
                except Exception:
                    pub_date = None

            items.append({
                'title': (title_elem.text or '').strip(),
                'url': url,
                'published': pub_date,
            })

    return items


def is_within_days(item: dict, days: int = 3) -> bool:
    """Check if item is within the last N days."""
    if item['published'] is None:
        return False
    cutoff = datetime.datetime.now() - datetime.timedelta(days=days)
    return item['published'] >= cutoff


def fetch_article_content(url: str) -> str:
    """Fetch article HTML using requests."""
    headers = {
        'User-Agent': 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36'
    }
    resp = requests.get(url, headers=headers, timeout=30)
    resp.raise_for_status()
    return resp.text


def html_to_markdown(html: str) -> str:
    """Convert HTML to markdown."""
    if HAS_HTML2TEXT:
        h = html2text.HTML2Text()
        h.ignore_links = False
        h.body_width = 0
        return h.handle(html)
    else:
        import re
        import html as ihtml
        html = re.sub(r'<(script|style).*?>.*?</\1>', '', html, flags=re.DOTALL|re.IGNORECASE)
        html = re.sub(r'<h1>(.*?)</h1>', r'# \1', html, flags=re.DOTALL|re.IGNORECASE)
        html = re.sub(r'<h2>(.*?)</h2>', r'## \1', html, flags=re.DOTALL|re.IGNORECASE)
        html = re.sub(r'<h3>(.*?)</h3>', r'### \1', html, flags=re.DOTALL|re.IGNORECASE)
        html = re.sub(r'<p>(.*?)</p>', r'\1\n\n', html, flags=re.DOTALL|re.IGNORECASE)
        html = re.sub(r'<a href="([^"]*)">([^<]*)</a>', r'[\2](\1)', html, flags=re.DOTALL|re.IGNORECASE)
        html = re.sub(r'<br\s*/?>', '\n', html, flags=re.DOTALL|re.IGNORECASE)
        html = re.sub(r'<[^>]+>', '', html)
        html = ihtml.unescape(html)
        return html.strip()


def sanitize_filename(name: str) -> str:
    """Create safe filename from title."""
    invalid = '<>:"/\\|?*'
    for ch in invalid:
        name = name.replace(ch, '_')
    name = name[:100]
    return name.strip()


def article_exists(item: dict, articles_dir: Path) -> bool:
    """Check if article markdown file already exists."""
    safe_title = sanitize_filename(item['title'])
    date_str = item['published'].strftime('%Y-%m-%d') if item['published'] else 'unknown'
    filename = f"{date_str}_{safe_title}.md"
    return (articles_dir / filename).exists()


def save_article(item: dict, content: str, articles_dir: Path):
    """Save article as markdown file."""
    safe_title = sanitize_filename(item['title'])
    date_str = item['published'].strftime('%Y-%m-%d') if item['published'] else 'unknown'
    filename = f"{date_str}_{safe_title}.md"
    filepath = articles_dir / filename

    date_line = item['published'].strftime('%Y-%m-%d %H:%M') if item['published'] else 'Unknown'

    md_content = f"""---
title: "{item['title']}"
url: "{item['url']}"
published: "{date_line}"
---

# {item['title']}

{content}

---
*Fetched from RSS on {datetime.datetime.now().strftime('%Y-%m-%d %H:%M:%S')}*
"""
    filepath.write_text(md_content, encoding='utf-8')
    return filepath


def main():
    parser = argparse.ArgumentParser(description='RSS Monitor - fetch latest article and output node info')
    parser.add_argument('--url', help='RSS feed URL (overrides config)')
    parser.add_argument('--config', default='.', help='Config directory with config.json')
    parser.add_argument('--days', type=int, default=3, help='Days to look back')
    parser.add_argument('--send', action='store_true', help='Send node info to Feishu')
    parser.add_argument('--clear', action='store_true', help='Clear latest.md after sending (if used)')

    args = parser.parse_args()

    # Determine RSS URL: arg > config file
    rss_url = args.url
    config_dir = Path(args.config)

    if not rss_url:
        config_path = config_dir / 'config.json'
        if config_path.exists():
            with open(config_path, 'r') as f:
                cfg = json.load(f)
                rss_url = cfg.get('rss_url')
        else:
            print("ERROR: RSS feed URL not provided. Set --url or create config.json with 'rss_url'.", file=sys.stderr)
            sys.exit(1)

    if not rss_url:
        print("ERROR: No RSS feed URL configured.", file=sys.stderr)
        sys.exit(1)

    output_dir = config_dir
    articles_dir = output_dir / 'articles'
    articles_dir.mkdir(exist_ok=True)

    # Step 1: Fetch RSS XML (overwrite)
    feed_xml_path = output_dir / 'feed.xml'
    xml_content = fetch_rss_xml(rss_url, feed_xml_path)

    # Step 2: Parse and filter recent items
    items = parse_feed(xml_content)
    recent_items = [item for item in items if is_within_days(item, args.days)]

    if not recent_items:
        print("没有找到最近3天内的文章")
        sys.exit(0)

    # Step 3: Find all recent items that are not yet cached
    new_items = [item for item in recent_items if not article_exists(item, articles_dir)]

    if not new_items:
        print("没有新文章")
        sys.exit(0)

    # Step 4: Fetch full content and save all new items
    for item in new_items:
        try:
            html = fetch_article_content(item['url'])
            md = html_to_markdown(html)
            save_article(item, md, articles_dir)
        except Exception as e:
            print(f"获取文章内容失败 ({item['title']}): {e}", file=sys.stderr)
            # Continue with other items even if one fails

    # Step 5: Output node info for each new item (using markdown link format for consistency)
    for item in new_items:
        date_line = item['published'].strftime('%Y-%m-%d %H:%M') if item['published'] else 'Unknown'
        print(f"""# 最新RSS节点

**标题**: {item['title']}

**发布日期**: {date_line}

**链接**: [查看原文]({item['url']})
""")

    # Step 6: Optionally send to Feishu (all in one message)
    if args.send:
        try:
            # Build combined message for all new items (using markdown link format for consistency)
            sections = []
            for idx, item in enumerate(new_items, 1):
                date_line = item['published'].strftime('%Y-%m-%d %H:%M') if item['published'] else 'Unknown'
                sections.append(f"""## {idx}. {item['title']}

- **发布日期**: {date_line}
- **链接**: [查看原文]({item['url']})
""")

            combined_message = "# RSS 更新汇总\n\n" + "\n".join(sections)

            result = subprocess.run(
                ['openclaw', 'message', 'send', '--target', 'ou_4bec49d80141982d31d1f1f67c943de7',
                 '--channel', 'feishu', '--message', combined_message],
                capture_output=True,
                text=True,
                timeout=60
            )
            if result.returncode == 0:
                print(f"✅ 已发送 {len(new_items)} 篇到飞书（一条消息）")
            else:
                print(f"发送失败: {result.stderr}", file=sys.stderr)
        except Exception as e:
            print(f"发送错误: {e}", file=sys.stderr)

    sys.exit(0)


if __name__ == '__main__':
    main()
