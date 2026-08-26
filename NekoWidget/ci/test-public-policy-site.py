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
LOCAL_ONLY_PAGES = (
    SITE / "app" / "index.html",
    SITE / "app" / "privacy" / "index.html",
    SITE / "app" / "support" / "index.html",
)
ALL_PAGES = PAGES + LOCAL_ONLY_PAGES


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
        for page in ALL_PAGES:
            self.assertTrue(page.is_file(), page)
            source = page.read_text(encoding="utf-8")
            self.assertIn('lang="ja"', source)
            self.assertIn('name="viewport"', source)
            self.assertIn("ねこのまど", source)

    def test_internal_links_resolve(self):
        for page in ALL_PAGES:
            for href in self.parsed(page).links:
                parsed = urllib.parse.urlparse(href)
                if parsed.scheme or href.startswith("#"):
                    continue
                target = (page.parent / parsed.path).resolve()
                if parsed.path.endswith("/") or target.is_dir():
                    target /= "index.html"
                self.assertTrue(target.is_file(), f"{page}: {href} -> {target}")

    def test_external_links_are_https(self):
        for page in ALL_PAGES:
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
            "この共有仕様は、内部TestFlightベータとして確認中です。App Storeで一般提供している版ではありません。",
            "1台のiPhoneで最大20個の名前付き非公開なまど",
            "1つのまどは作成者と信頼できる招待相手1人だけ",
            "各参加者は、承認した最大4台のiPhone",
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

        privacy = "".join(self.parsed(PAGES[1]).text)
        self.assertIn("写真共有が有効な内部TestFlight共有ベータでは", privacy)
        self.assertNotIn("写真共有が有効な現行版では", privacy)
        for phrase in (
            "写真アプリに「うちの子」アルバムを作成・更新",
            "元写真のアルバム所属を追加・解除",
            "このアルバム連携では元写真を複製、書き出し、アップロードせず",
            "写真アプリとiCloud写真の同期はAppleと利用者の設定によります",
            "「うちの子」アルバムの構成がほかのApple端末へ同期されることがあります",
        ):
            self.assertIn(phrase, privacy)

    def test_received_memory_import_is_explicit_and_permanent(self):
        for page in (PAGES[1], PAGES[3]):
            text = "".join(self.parsed(page).text)
            for phrase in (
                "「思い出に残す」",
                "「届いた写真」",
                "明示的に選",
                "位置情報を除いた最大2,048px",
                "写真アプリへ",
                "通常の「思い出」と写真まとめ",
                "相手には通知しません",
                "iCloud写真",
                "90日",
                "500枚",
                "256MiB",
                "共有解除",
                "ブロック",
                "アプリ削除",
                "写真アプリには残",
                "ハート",
            ):
                self.assertIn(phrase, text, f"{page}: {phrase}")
            self.assertNotIn("memory mark", text, page)
            self.assertNotIn("無料・期限付き", text, page)
            self.assertNotIn("まど内履歴", text, page)

    def test_release_safety_facts_are_present(self):
        privacy = "".join(self.parsed(PAGES[1]).text)
        community = "".join(self.parsed(PAGES[2]).text)
        support = "".join(self.parsed(PAGES[3]).text)
        for phrase in (
            "エンドツーエンド暗号化",
            "通報専用公開鍵",
            "ACK後7日",
            "未受領の通常暗号文：commit後30日",
            "通知用デバイストークン",
            "暗号化して最大35日保持",
            "Apple Push Notification service（APNs）",
            "写真、まど名、相手名、撮影日時、写真ID、取得URL、暗号鍵を含めません",
            "写真を含まないサーバー側記録",
            "生成AIの学習に利用しません",
            "「思い出」に残した一枚で「写真を書き出す」を明示的に選んだ場合だけ",
            "長辺2,048px以下のJPEG",
            "アプリ自身が管理する書き出し用の一時ファイルは作りません",
            "iOSまたは共有先が処理のためにデータのコピーを作成・保持する場合があります",
        ):
            self.assertIn(phrase, privacy)
        for phrase in ("通報", "ブロック", "48時間以内", "削除対象", "再試行"):
            self.assertIn(phrase, community)
        self.assertNotIn("7日の期限を超えて保持しません", community)
        for phrase in (
            "GitHub Issues",
            "TestFlight",
            "招待コード",
            "緊急通報先ではありません",
            "iOS 18",
            "Widget更新はbest effort",
            "「思い出」の写真を書き出す",
            "共有先は利用者が選び、そのサービスとポリシーが適用されます",
        ):
            self.assertIn(phrase, support)

    def test_no_placeholder_or_personal_email_is_published(self):
        sources = "\n".join(page.read_text(encoding="utf-8") for page in ALL_PAGES)
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

    def test_local_only_pages_link_to_each_other(self):
        expected = {page.resolve() for page in LOCAL_ONLY_PAGES}
        for page in LOCAL_ONLY_PAGES:
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

    def test_local_only_revision_is_visible_and_fixed(self):
        for page in LOCAL_ONLY_PAGES:
            parser = self.parsed(page)
            self.assertEqual("2026-08-26", parser.meta.get("neko-policy-revision"), page)
            self.assertIn("最終更新日：2026年8月26日", "".join(parser.text), page)

    def test_local_only_capability_boundary_is_consistent(self):
        required = (
            "完全ローカル版",
            "現在の共有ベータ版とは別の仕様",
            "この完全ローカル版では",
            "写真の読み込み、解析、猫判定、一覧、Widget用画像の処理は端末内だけ",
            "ほかの利用者とのネットワーク写真共有・招待・自動送信・受信機能はなく",
            "アプリから開発者のサーバーへ通信しません",
            "公開フィード、検索、フォローもありません",
            "開発者の解析サービスへ自動接続せず、広告やトラッキングを行いません",
            "写真アプリに「うちの子」アルバムを作成・更新",
            "元写真のアルバム所属を追加・解除",
            "このアルバム連携では元写真を複製、書き出し、アップロードせず",
            "写真アプリとiCloud写真の同期はAppleと利用者の設定によります",
            "「うちの子」アルバムの構成がほかのApple端末へ同期されることがあります",
            "アプリを削除しても、「うちの子」アルバムやその構成が写真アプリに残ることがあります",
            "アプリとWidgetの専用領域にあるデータはiOSにより削除されます",
            "本アプリが写真やデータを自動で開発者のサーバーへアップロードすることはありません",
            "「思い出」の一枚のJPEG、写真PDF、検証JSON、診断ログの書き出しを明示的に選ぶと、iOSの共有シートが開きます",
            "共有先のサービスとポリシーが適用されます",
            "単写真JPEGは長辺2,048px以下",
            "位置情報、撮影日時、元のファイル名",
            "アプリ自身が管理する書き出し用の一時ファイルを作らず",
            "iOSまたは共有先が処理のためにコピーを作成・保持する場合があります",
            "写真PDFには利用者が選んだ写真が含まれます",
            "識別子や診断情報が含まれる場合があります",
            "内容と共有先を確認してから共有してください",
            "非公開で連絡できるプライバシー問い合わせ窓口は現在未掲載です",
            "App Storeで一般提供する前に、このページへ有効な非公開窓口を掲載する必要があります",
            "一般公開の提出準備は完了していません",
        )
        for page in LOCAL_ONLY_PAGES:
            text = "".join(self.parsed(page).text)
            for phrase in required:
                self.assertIn(phrase, text, f"{page}: {phrase}")

    def test_local_only_privacy_facts_are_explicit(self):
        privacy = "".join(self.parsed(LOCAL_ONLY_PAGES[1]).text)
        for phrase in (
            "開発者によるデータ収集を行いません",
            "CloudKitやアプリ独自のiCloudコンテナも使用しません",
            "共有相手、招待、送信待ち、届いた写真の一覧、サーバー上の写真は作成しません",
            "開発者の共有サーバーや解析サービスへ自動接続しません",
            "データ販売、生成AIの学習にも利用しません",
        ):
            self.assertIn(phrase, privacy)

    def test_local_only_false_policy_claims_are_absent(self):
        forbidden = (
            "写真アプリやiCloudへ独自に保存することもありません",
            "写真アプリやiCloudへ独自に保存することはありません",
            "写真アプリやiCloudへ独自に保存しません",
            "共有・招待・送信・受信はなく",
            "選んだ写真、縮小画像、Widget表示用の派生画像を外部へ送信しません",
            "写真、縮小画像、判定結果、Widget表示用画像などの派生画像を、開発者やその他の外部サーバーへ送信しません",
            "技術的な問い合わせとプライバシーに関する連絡方法は",
        )
        for page in LOCAL_ONLY_PAGES:
            text = "".join(self.parsed(page).text)
            for phrase in forbidden:
                self.assertNotIn(phrase, text, f"{page}: {phrase}")

    def test_photo_album_disclosure_stays_aligned_with_implementation(self):
        service = PHOTO_ALBUM_SERVICE.read_text(encoding="utf-8")
        settings = SETTINGS_VIEW.read_text(encoding="utf-8")
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
        self.assertIn(
            "写真を複製せず、見つけた猫写真を写真アプリのアルバムへ反映します。",
            settings,
        )
        self.assertIn("NSPhotoLibraryAddUsageDescription", info)
        self.assertIn("「思い出に残す」を選んだ届いた写真", info)
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

    def test_local_only_support_reuses_existing_public_routes(self):
        support = "".join(self.parsed(LOCAL_ONLY_PAGES[2]).text)
        for phrase in (
            "TestFlight",
            "GitHub Issues",
            "Build番号",
            "公開してよい情報だけ",
            "緊急通報先ではありません",
            "GitHub Issuesは、個人情報を含まない技術的な問い合わせだけ",
        ):
            self.assertIn(phrase, support)

    def test_testflight_checks_the_exact_policy_profile_before_signing(self):
        workflow = TESTFLIGHT_WORKFLOW.read_text(encoding="utf-8")
        selector_name = "- name: Select fail-closed release mode"
        setup_name = "- name: Set up Node.js for public policy gate"
        gate_name = "- name: Validate public policy for selected release mode"
        signing_name = "- name: Install distribution certificate and provisioning profiles"
        self.assertLess(workflow.index(selector_name), workflow.index(setup_name))
        self.assertLess(workflow.index(setup_name), workflow.index(gate_name))
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
        self.assertEqual(gate.count('policy_revision="2026-08-25"'), 1)
        disabled = gate.split("disabled)", 1)[1].split(";;", 1)[0]
        self.assertIn('policy_profile="local-only"', disabled)
        self.assertIn(
            'policy_site_base="https://soso-so-27.github.io/neko-widget/app/"',
            disabled,
        )
        media = gate.split("media-staging)", 1)[1].split(";;", 1)[0]
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
