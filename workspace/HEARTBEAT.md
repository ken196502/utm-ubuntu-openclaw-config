# HEARTBEAT.md

## Twitter Scraper Check
- Always spawn a subagent to perform the Twitter scraper check
- The subagent should:
  0. Check cooldown: Read `memory/last_twitter_check_timestamp.txt`. If the file exists and its timestamp is within the last 30 minutes, report "Cooldown active (last run < 30 min ago) — skipping Twitter scraper check" and exit early.
  1. Scrape the OpenClaw Twitter list (list-id: 2023053272517660833) with limit 20 and save to database (db-name: openclaw)
  2. If all tweets already exist (no new tweets), then search for popular tweets using search script with query "openclaw min_faves:100" and limit 10 --fallback
  3. If tweets with 100+ likes are found:
     - Identify the most popular tweet (highest likes), but if there are multiple tweets with similar content (e.g., openclaw updates), prioritize the latest one
     - Fetch detailed content: text, images, videos, and hot replies
     - Summarize the keypoints from that tweet and its engagement
  4. If no tweets got 100+ likes, skip (no summary needed)
  5. After successful completion, write the current UTC timestamp to `memory/last_twitter_check_timestamp.txt` (format: YYYY-MM-DD HH:MM:SS UTC)
- Report the subagent's results
