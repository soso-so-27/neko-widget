# Beta App Review Notes — draft aligned with Build161

Internal status: prepared copy only. Build161 was uploaded for the existing internal TestFlight; this document does not establish external-test eligibility, a submitted review, approval, or an invitation. Paste only the body below after the target build and external-test authorization have been confirmed.

---

Neko no Mado requires iOS 17.1 or later. This is a free limited beta with no purchases or automatic paid conversion. Plus is not on sale. No app sign-in or review credentials are needed for the solo and public-window experience.

The proposed external test is limited to one known, trusted tester in a dedicated group for the specifically approved build, with the public invitation link disabled. This is not an open beta.

**Start without personal photos or another person**

Skip the initial photo check if desired. Open まど (Windows), tap +, and choose 公開まどを探す (Explore public windows). The available windows are どこかの猫 (operator-selected cat images) and おひるね (napping cats). Open an image to enlarge it, close it, then choose このまどを受け取る (Receive this window). Browsing does not subscribe automatically. Each window can be stopped separately from its management menu.

These are read-only, operator-published HTTPS feeds. Current preview images are AI-generated and carry the credit ねこのまど（AI生成）. They are public content, separate from private encrypted messages. Receiving a public window does not upload the user's photo library. There is no public user-posting feature, user directory, or public heart/reply feature.

The widget guide explains how to add a Home Screen widget and select its window. Tapping a displayed photo opens that photo; unavailable photos are not silently replaced by another photo in the viewer. Widget refresh timing is controlled by iOS and is not guaranteed to be immediate. Published images may expire or be withdrawn.

**Optional personal-photo and private-sharing flows**

Allow access to selected photos or the photo library to use personal photos. Cat-photo detection runs on device within that permission. Open a photo, enlarge it, keep it in 思い出 (Memories), and view it there. Cat registration is optional. Monthly photo letters and seasonal movies depend on available photos; they are not required to use the app.

Private sharing requires two iPhones. Create a private まど on one phone and join using its invitation code on the other. Compare all 12 words of the verification phrase on both phones and approve only if they match. Enable Settings > Privacy & Security > Sensitive Content Warning and complete the app's sharing consent when requested.

Open a permitted local photo, choose まどへ届ける, select a connected private window, and review the image and destination. A short caption is optional. The destination can be changed before confirming; やめる cancels without sending. Private photos and captions use end-to-end encryption. The app reduces the image size and removes location metadata before sending. A sent confirmation means server acceptance, not receipt or viewing by the other person.

The recipient can read the full caption and send a heart in the app; the private-window widget also offers a heart. To keep a received photo, use 思い出に残す in the app and complete the confirmation/permission for importing into Photos. The imported copy may sync according to iCloud Photos settings and remains in Photos after sharing ends or the participant is blocked. Public-window subscription does not provide these private-sharing actions.

**Safety and support**

Encrypted in-app reporting is disabled in this beta. Please use TestFlight feedback without attaching photos, invitation codes, verification phrases, or keys. The designated operator is responsible for initial safety-feedback review within 48 hours, including holidays, and for stopping sharing when needed.

A received photo's safety menu can block the other participant and end sharing. Settings > ブロックした共有 lists supported blocks made on this iPhone. Removing a block does not restore the old connection or deleted shared photos; sharing again requires a new invitation and verification by both people. Blocks from older versions or another iPhone cannot be removed through this list. Separately imported Photos copies cannot be remotely recalled.

Privacy: https://soso-so-27.github.io/neko-widget/privacy/

Support: https://soso-so-27.github.io/neko-widget/support/

Community standards: https://soso-so-27.github.io/neko-widget/community/
