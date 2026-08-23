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
        self.meta: dict[str, str] = {}
        self.text: list[str] = []

    def handle_starttag(self, tag, attrs):
        attributes = dict(attrs)
        if tag == "a":
            href = attributes.get("href")
            if href:
                self.links.append(href)
        if tag == "meta":
            name = attributes.get("name")
            content = attributes.get("content")
            if name and content:
                self.meta[name] = content

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

    def test_every_page_links_to_every_public_policy_page(self):
        expected = {page.resolve() for page in PAGES}
        for page in PAGES:
            linked: set[pathlib.Path] = set()
            for href in self.parsed(page).links:
                parsed = urllib.parse.urlparse(href)
                if parsed.scheme or href.startswith("#"):
                    continue
                target = (page.parent / parsed.path).resolve()
                if parsed.path.endswith("/") or target.is_dir():
                    target /= "index.html"
                linked.add(target)
            self.assertTrue(expected.issubset(linked), f"{page}: missing {expected - linked}")

    def test_policy_revision_is_valid_and_shared(self):
        revisions: dict[pathlib.Path, str] = {}
        for page in PAGES:
            revision = self.parsed(page).meta.get("neko-policy-revision", "")
            self.assertRegex(revision, r"^\d{4}-\d{2}-\d{2}$", page)
            revisions[page] = revision
        self.assertEqual(1, len(set(revisions.values())), revisions)

        year, month, day = (int(part) for part in next(iter(revisions.values())).split("-"))
        visible_revision = f"最終更新日：{year}年{month}月{day}日"
        for page in PAGES[1:]:
            self.assertIn(visible_revision, "".join(self.parsed(page).text), page)

    def test_private_window_capability_boundary_is_consistent(self):
        required = (
            "名前を付けた1つの非公開なまど",
            "信頼できる招待相手1人",
            "2人・各1台",
            "家族に限定しません",
            "公開フィード、検索、フォロー、匿名の出会いはありません",
        )
        legacy_family_copy = (
            "家族のまど",
            "家族共有",
            "招待した家族",
            "家族間",
            "少人数の家族",
            "写真は家族へ",
        )
        for page in PAGES:
            text = "".join(self.parsed(page).text)
            for phrase in required:
                self.assertIn(phrase, text, page)
            for phrase in legacy_family_copy:
                self.assertNotIn(phrase, text, page)

    def test_keep_memory_is_a_bounded_local_bookmark(self):
        for page in (PAGES[1], PAGES[3]):
            text = "".join(self.parsed(page).text)
            for phrase in (
                "「思い出に残す」",
                "まど内履歴",
                "期限付き",
                "bookmark",
                "JPEGを複製しません",
                "写真アプリやiCloudへ保存せず",
                "90日",
                "500枚",
                "256MiB",
                "保持上限を延長しません",
                "expiry",
                "unlink",
                "block",
                "reinstall",
            ):
                self.assertIn(phrase, text, f"{page}: {phrase}")

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
        for forbidden in (
            "todo",
            "tbd",
            "example.com",
            "example.invalid",
            "your-email",
            "replace-me",
            "gmail.com",
        ):
            self.assertNotIn(forbidden, lowered)


if __name__ == "__main__":
    unittest.main()
