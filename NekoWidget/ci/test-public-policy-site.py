import html.parser
import pathlib
import subprocess
import textwrap
import unittest
import urllib.parse


ROOT = pathlib.Path(__file__).resolve().parents[2]
SITE = ROOT / "docs"
TESTFLIGHT_WORKFLOW = ROOT / ".github" / "workflows" / "testflight.yml"
PHOTO_ALBUM_SERVICE = ROOT / "NekoWidget" / "NekoWidget" / "Services" / "PhotoAlbumService.swift"
SETTINGS_VIEW = ROOT / "NekoWidget" / "NekoWidget" / "Views" / "SettingsView.swift"
INFO_PLIST = ROOT / "NekoWidget" / "NekoWidget" / "Info.plist"
LIKED_PHOTOS_VIEW = ROOT / "NekoWidget" / "NekoWidget" / "Views" / "LikedPhotosView.swift"
LOG_VIEW = ROOT / "NekoWidget" / "NekoWidget" / "Views" / "LogView.swift"
PHOTO_BOOK_EXPORTER = ROOT / "NekoWidget" / "NekoWidget" / "Services" / "PhotoBookPDFExporter.swift"
JSON_EXPORTER = ROOT / "NekoWidget" / "NekoWidget" / "Services" / "JSONExporter.swift"
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
        required_by_page = (
            (
                'iPhoneの写真から猫の写真を見つけて',
                'アルバムとホーム画面のウィジェットに出すアプリ',
                'お気に入りの1枚は「まど」で、家族や猫友に届けられます',
                '公開フィード、検索、フォロー、匿名の出会いはありません',
                '広告もありません',
                'iPhoneの中だけで扱うもの',
                'まど・家族の手帳・自動保存で扱う情報',
                '保持と削除を説明します',
                '通報とブロック、対応の方針',
            ),
            (
                '1つのまどは6人まで',
                '1つのまどにつき1人1日5枚まで',
                'エンドツーエンド暗号化してから送ります',
                '中身を読む鍵を持ちません',
                '確認用の画像は7日で消えます',
                '問題なし・解除と決めたものは決定から1年で消します',
                '暗号化して最大35日保持',
                '購読の終わりから12か月',
                '知らせが届いてから少なくとも30日は待ちます',
            ),
            (
                '1つのまどは6人まで',
                '入れるのは招待された人だけ',
                '公開フィード、検索、フォロー、匿名の出会いはありません',
                '届け先が、意図した名前のまどであることを確認する',
                '運営者だけが開ける鍵で暗号化して送ります',
                '受付番号が出る',
                'その相手からの新しい写真を止められます',
                '確認用の画像は7日で消し',
                '停止が続いている間は残し、問題なし・解除と決めたものは決定から1年で消します',
            ),
            (
                '毎日の入れ替わりはPlusの機能',
                'まどを作った人がPlusを使っている必要があります',
                '招待された人は無料',
                '1人1日5枚まで',
                '1つのまどにつき新しいものから500枚まで',
                '写真アプリに保存してください',
                'それまでの記録は消えません',
                '鍵はiPhoneごとに作る',
                '緊急通報先ではありません',
            ),
        )
        legacy_family_copy = (
            "家族のまど",
            "家族共有",
            "招待した家族",
            "家族間",
            "少人数の家族",
            "写真は家族へ",
        )
        for page, required in zip(PAGES, required_by_page, strict=True):
            text = "".join(self.parsed(page).text)
            for phrase in required:
                self.assertIn(phrase, text, page)
            for phrase in legacy_family_copy:
                self.assertNotIn(phrase, text, page)

        privacy = "".join(self.parsed(PAGES[1]).text)
        self.assertIn("写真・ひとこと・まどの名前・表示名は、まどの鍵でエンドツーエンド暗号化してから送ります", privacy)
        self.assertNotIn("写真共有が有効な現行版では", privacy)
        # The app no longer writes a 「うちの子」 album (10/31); the page must not promise one.
        self.assertNotIn("「うちの子」アルバム", privacy)

    def test_received_memory_import_is_explicit_and_permanent(self):
        required_by_page = (
            (
                '長辺2,048px以下のJPEG',
                '位置情報などの元情報は除きます',
                '受け取ったiPhoneの中に、1つのまどにつき新しいものから500枚まで残ります',
                'すでに相手のiPhoneに届いた写真',
                '相手が写真アプリに保存した写真',
                '本サービスから消せません',
                '「写真を書き出す」を明示的に選んだ場合だけ',
                '位置情報、撮影日時、元のファイル名、EXIFなどの元情報を除いて',
                'iOSの共有シートへ渡します',
                'アプリ自身が管理する書き出し用の一時ファイルは作りません',
                '開発者のサーバーへ自動送信せず',
                '共有先は利用者が選び',
                'そのサービスとポリシーが適用されます',
                'iOSまたは共有先が処理のためにデータのコピーを作成・保持する場合があります',
                'まどを抜けたとき・まどを閉じたとき',
                '新しい写真は届かなくなり、サーバーから新しく受け取る権限も止まります',
                'すでにあなたのiPhoneに届いた写真は「前のまど」として残ります',
            ),
            (
                '1つのまどにつき新しいものから500枚まで',
                'そのiPhoneの中に残ります',
                '残したい写真は、写真アプリに保存してください',
                '招待された人は無料',
                '1つのまどに届けられるのは、1人1日5枚まで',
                '通知を許可していれば',
                '届いたときに知らせます',
                'それまでの記録は消えません',
                '写真のコピー・メモ・この子のことが戻ります',
                'もう一度招待を受けて参加してください',
                '鍵はiPhoneごとに作る',
                '解約しても、写真・まど・メモは消えません',
                '通報とブロックができます',
                'ブロックすると、その相手からの写真は届かなくなります',
                '通報すると受付番号が出る',
                '写真や個人の情報は、公開の場所に書かないでください',
            ),
        )
        for page, required in zip((PAGES[1], PAGES[3]), required_by_page, strict=True):
            text = "".join(self.parsed(page).text)
            for phrase in required:
                self.assertIn(phrase, text, f"{page}: {phrase}")
            self.assertNotIn("memory mark", text, page)
            self.assertNotIn("無料・期限付き", text, page)
            self.assertNotIn("まど内履歴", text, page)
            # The local store keeps 500 per window with no time limit (1102a).
            self.assertNotIn("90日", text, page)
            self.assertNotIn("見る権限も止まります", text, page)

    def test_release_safety_facts_are_present(self):
        privacy = "".join(self.parsed(PAGES[1]).text)
        community = "".join(self.parsed(PAGES[2]).text)
        support = "".join(self.parsed(PAGES[3]).text)
        overview = "".join(self.parsed(PAGES[0]).text)
        for phrase in ("通報時の例外", "通報、ブロック"):
            self.assertNotIn(phrase, overview)
        for phrase in (
            "エンドツーエンド暗号化",
            "確認用の画像は7日で消えます",
            "対応の記録は、停止が続いている間は残し、問題なし・解除と決めたものは決定から1年で消します",
            "受け取ったあとはその人の分が最長7日",
            "あなたが通報したときの確認用の画像、あなたが「写真を書き出す」で共有先に渡したもの",
            "まだ受け取っていない人がいる間は最長30日",
            "通知用デバイストークン",
            "暗号化して最大35日保持",
            "Apple Push Notification service（APNs）",
            "まどと写真の不透明な識別子",
            "写真そのもの、まど名、相手名、撮影日時、取得URL、暗号鍵を含めません",
            "写真を含まないサーバー側記録",
            "生成AIの学習に利用しません",
            "お気に入りや届いた写真で「写真を書き出す」を明示的に選んだ場合だけ",
            "長辺2,048px以下のJPEG",
            "アプリ自身が管理する書き出し用の一時ファイルは作りません",
            "iOSまたは共有先が処理のためにデータのコピーを作成・保持する場合があります",
        ):
            self.assertIn(phrase, privacy)
        self.assertNotIn("一般的な通知文だけを送ります", privacy)
        self.assertNotIn("写真ID、取得URL", privacy)
        for phrase in (
            '確認用の画像は7日で消し',
            '停止が続いている間は残し、問題なし・解除と決めたものは決定から1年で消します',
            'この相手をブロック',
            '運営者だけが開ける鍵で暗号化して送ります',
            '48時間以内',
            '通報されていない通常の写真を、運営者が復号して中身を見ることはありません',
        ):
            self.assertIn(phrase, community)
        self.assertNotIn("7日の期限を超えて保持しません", community)
        for phrase in (
            'support@nekonomado.com',
            '1つのまどにつき新しいものから500枚まで',
            '「わたしの Plus で再開する」を押すか、だれかがPlusを始めると戻ります',
            '確かめられると自動で戻ります',
            '通報とブロックができます',
            'ブロックすると、その相手からの写真は届かなくなります',
            '通報すると受付番号が出る',
            '緊急通報先ではありません',
            '1人1日5枚まで',
            '切り替わる時刻はiOSが決める',
            '写真アプリに保存してください',
            '写真、招待リンク、他の人の名前やメールアドレスは送らないでください',
        ):
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

    def test_photo_album_disclosure_stays_aligned_with_implementation(self):
        service = PHOTO_ALBUM_SERVICE.read_text(encoding="utf-8")
        info = INFO_PLIST.read_text(encoding="utf-8")
        for phrase in (
            "PHAssetCollectionChangeRequest.creationRequestForAssetCollection",
            "request.addAssets(desiredAssets)",
            "request.addAssets(additions)",
            "request.removeAssets(removals)",
        ):
            self.assertIn(phrase, service)
        self.assertIn("PHAssetCreationRequest.forAsset()", service)
        self.assertIn("request.addResource", service)
        # The album's Settings screen was removed (10/31); the app no longer
        # carries this sentence. The public privacy page still describes the
        # album and is updated separately with the owner's approval.
        self.assertIn("NSPhotoLibraryAddUsageDescription", info)
        self.assertIn("「自分のお気に入りに追加」を選んだ届いた写真", info)
        self.assertIn("写真を自動で追加することはありません", info)

    def test_explicit_export_disclosure_stays_aligned_with_implementation(self):
        liked_photos = LIKED_PHOTOS_VIEW.read_text(encoding="utf-8")
        settings = SETTINGS_VIEW.read_text(encoding="utf-8")
        log_view = LOG_VIEW.read_text(encoding="utf-8")
        photo_book = PHOTO_BOOK_EXPORTER.read_text(encoding="utf-8")
        json_exporter = JSON_EXPORTER.read_text(encoding="utf-8")
        memory_jpeg_exporter = photo_book.split("enum PhotoBookPDFExportError", 1)[0]
        self.assertIn("explicitly selected", photo_book)
        self.assertIn("image.draw", photo_book)
        self.assertIn(
            "uniqueSelection.count == selectedIdentifiers.count",
            photo_book,
        )
        for phrase in (
            "struct MemoryPhotoJPEGExporter",
            "MemoryPhotoExportPolicy.selection",
            "WidgetSourceImageNormalizer.normalizedUIImage",
            "MomentCanonicalPreviewBuilder.build(image: normalized)",
            "options.version = .current",
            "options.resizeMode = .exact",
            "options.deliveryMode = .highQualityFormat",
            "options.isNetworkAccessAllowed = true",
            "jpeg: preview.jpeg",
        ):
            self.assertIn(phrase, memory_jpeg_exporter)
        self.assertNotIn("PHAssetResource", memory_jpeg_exporter)
        self.assertNotIn("temporaryDirectory", memory_jpeg_exporter)
        self.assertIn("UIActivityViewController", liked_photos)
        for phrase in (
            'Label("写真を書き出す", systemImage: "square.and.arrow.up")',
            "NSItemProvider()",
            'itemProvider.suggestedName = "neko-memory.jpg"',
            "UTType.jpeg.identifier",
            "UIActivityItemsConfiguration(itemProviders: [itemProvider])",
            "UIActivityViewController(activityItemsConfiguration: configuration)",
        ):
            self.assertIn(phrase, liked_photos)
        self.assertIn("検証データをJSONで書き出す", settings)
        self.assertIn("UIActivityViewController", settings)
        self.assertIn("Diagnostic log export failed", log_view)
        self.assertIn("UIActivityViewController", log_view)
        self.assertIn("container.encode(snapshot.assets", json_exporter)
        self.assertIn("albumLocalIdentifier", json_exporter)

    def test_testflight_checks_the_exact_policy_profile_before_signing(self):
        workflow = TESTFLIGHT_WORKFLOW.read_text(encoding="utf-8")
        selector_name = "- name: Select fail-closed release mode"
        setup_name = "- name: Set up Node.js for public policy gate"
        gate_name = "- name: Validate public policy for selected release mode"
        signing_name = "- name: Install distribution certificate and provisioning profiles"
        self.assertLess(workflow.index(setup_name), workflow.index(selector_name))
        self.assertLess(workflow.index(selector_name), workflow.index(gate_name))
        self.assertLess(workflow.index(gate_name), workflow.index(signing_name))

        selector = workflow.split(selector_name, 1)[1].split("\n      - name:", 1)[0]
        self.assertIn('echo "Unknown release_mode: $SELECTED_RELEASE_MODE"', selector)
        self.assertIn("exit 1", selector)

        setup = workflow.split(setup_name, 1)[1].split("\n      - name:", 1)[0]
        self.assertIn(
            "actions/setup-node@a0853c24544627f65ddf259abe73b1d18a591444",
            setup,
        )
        self.assertIn('node-version: "22"', setup)

        gate = workflow.split(gate_name, 1)[1].split("\n      - name:", 1)[0]
        self.assertEqual(gate.count('policy_revision="2026-11-02"'), 2)
        self.assertNotIn("2026-08-", gate)
        disabled = gate.split("disabled)", 1)[1].split(";;", 1)[0]
        self.assertIn("Local-only public policy retired; disabled release is unavailable.", disabled)
        self.assertIn("exit 1", disabled)
        self.assertNotIn("policy_site_base=", disabled)
        media = gate.split("media-staging)", 1)[1].split(";;", 1)[0]
        self.assertIn('policy_revision="2026-11-02"', media)
        self.assertIn('policy_profile="sharing-beta"', media)
        self.assertIn(
            'policy_site_base="https://soso-so-27.github.io/neko-widget/"',
            media,
        )
        skipped = gate.split("review-preview|pairing-only)", 1)[1].split(";;", 1)[0]
        self.assertIn(
            "SKIP public policy gate: release_mode=$SELECTED_RELEASE_MODE does not use a public policy profile.",
            skipped,
        )
        self.assertIn("exit 0", skipped)
        for fragment in (
            'node "$PROJECT_DIRECTORY/SharingService/scripts/check-public-policy-site.mjs"',
            '--profile "$policy_profile"',
            '--site-base "$policy_site_base"',
            '--expected-revision "$policy_revision"',
        ):
            with self.subTest(fragment=fragment):
                self.assertIn(fragment, gate)
        for forbidden in ("wrangler", "emergency-off", "curl -x", "cloudflare"):
            with self.subTest(forbidden=forbidden):
                self.assertNotIn(forbidden, gate.lower())

        shell_source = (
            textwrap.dedent(gate.split("run: |", 1)[1]).lstrip().replace("\r", "")
        )
        syntax = subprocess.run(
            ["bash", "-n"],
            input=shell_source.encode("utf-8"),
            capture_output=True,
            check=False,
        )
        self.assertEqual(
            syntax.returncode,
            0,
            syntax.stderr.decode("utf-8", errors="replace"),
        )


if __name__ == "__main__":
    unittest.main()
