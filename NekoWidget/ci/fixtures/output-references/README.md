# Output reference images

Only generated, synthetic fixtures belong here. Never add real people, real cats,
owner photos, or exported user records: this repository is public.

`NekoWidgetTests` is an app-hosted iOS Simulator XCTest target with
`@testable import NekoWidget`. Renderer reference comparisons will be added by
Claude. The initial test validates the host and UIKit image round trip only;
it does **not** establish that the product's rendered outputs match references.

Use fixed dimensions, locale, appearance and content-size category for each
reference. Attach actual/expected/difference images on failure. Updating a
reference must be an explicit reviewed change, never an automatic CI action.
