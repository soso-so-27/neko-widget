import html.parser
import pathlib
import unittest
import urllib.parse


ROOT = pathlib.Path(__file__).resolve().parents[2]
SITE = ROOT / "docs"
PAGES = (
    SITE / "index.html",
    SITE / "privacy" / "index.html",
    SITE / "community" / "index.html",
    SITE / "support" / "index.html",
)


class PageParser(html.parser.HTMLParser):
    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.links: list[str] = []
        self.text: list[str] = []

    def handle_starttag(self, tag, attrs):
        if tag == "a":
            href = dict(attrs).get("href")
            if href:
                self.links.append(href)

    def handle_data(self, data):
        self.text.append(data)


class PublicPolicySiteTests(unittest.TestCase):
    def parsed(self, path: pathlib.Path) -> PageParser:
        parser = PageParser()
        parser.feed(path.read_text(encoding="utf-8"))
        parser.close()
        return parser

    def test_expected_pages_and_mobile_metadata_exist(self):
        for page in PAGES:
            self.assertTrue(page.is_file(), page)
            source = page.read_text(encoding="utf-8")
            self.assertIn('lang="ja"', source)
            self.assertIn('name="viewport"', source)
            self.assertIn("ねこのまど", source)

    def test_internal_links_resolve(self):
        for page in PAGES:
            for href in self.parsed(page).links:
                parsed = urllib.parse.urlparse(href)
                if parsed.scheme or href.startswith("#"):
                    continue
                target = (page.parent / parsed.path).resolve()
                if parsed.path.endswith("/") or target.is_dir():
                    target /= "index.html"
                self.assertTrue(target.is_file(), f"{page}: {href} -> {target}")

    def test_external_links_are_https(self):
        for page in PAGES:
            for href in self.parsed(page).links:
                parsed = urllib.parse.urlparse(href)
                if parsed.scheme:
                    self.assertEqual(parsed.scheme, "https", f"{page}: {href}")

    def test_release_safety_facts_are_present(self):
        privacy = "".join(self.parsed(PAGES[1]).text)
        community = "".join(self.parsed(PAGES[2]).text)
        support = "".join(self.parsed(PAGES[3]).text)
        for phrase in (
            "エンドツーエンド暗号化",
            "通報専用公開鍵",
            "ACK後7日",
            "未受領の通常暗号文：commit後30日",
            "写真を含まないサーバー側記録",
            "生成AIの学習に利用しません",
        ):
            self.assertIn(phrase, privacy)
        for phrase in ("通報", "ブロック", "48時間以内", "削除対象", "再試行"):
            self.assertIn(phrase, community)
        self.assertNotIn("7日の期限を超えて保持しません", community)
        for phrase in ("GitHub Issues", "TestFlight", "招待コード", "緊急通報先ではありません"):
            self.assertIn(phrase, support)

    def test_no_placeholder_or_personal_email_is_published(self):
        sources = "\n".join(page.read_text(encoding="utf-8") for page in PAGES)
        lowered = sources.lower()
        for forbidden in ("todo", "example.com", "your-email", "gmail.com"):
            self.assertNotIn(forbidden, lowered)


if __name__ == "__main__":
    unittest.main()
