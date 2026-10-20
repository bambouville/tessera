# Markdown Quick Look images

Remote Files Quick Look on iOS and Android renders Markdown images whose destinations are paths on the document's host. Relative paths use the remote document's parent directory; absolute paths start at that host's root. `../`, URI-escaped filenames, reference-style images, and local `file:///` URLs are supported. Images in headings, prose, lists, quotes, and table cells use the same renderer. Links around images remain clickable.

Images travel through the existing Files/SFTP bridge, shared by SSH, SSH+tmux, Mosh, and Mosh+tmux. No destination is interpreted as a path in the phone or tablet filesystem. Host-qualified URLs, HTTP images, data URLs, and raw HTML are not fetched by this local-image feature. Agent Center continues to show image alt text without fetching images.

The original Markdown remains unchanged for sharing and Android's source view. Generated preview images stay in private staging/cache storage. Supported raster files are decoded using the platform image decoder and rendered as a static preview. Missing, unsupported, or over-limit images keep their alt text.

Each preview stages at most 32 distinct destinations, with an 8 MiB per-image and 32 MiB total download budget. Thumbnails are at most 2048 pixels on their longest edge; decoded images share a 16-megapixel per-document budget. Repeated references reuse decoded images. iOS opens the text before fetching images and cancels pending image downloads on dismissal. Android stages images inside the existing cancellable file-presentation transfer.

Android requires Android 13 / API 33 or newer. Gradle library/application floors and the physical installer enforce the same minimum. The native shared core may retain an older compatible ABI target.

## Regression gates

- `swift test --package-path Packages/TesseraCore --filter AgentMarkdown` covers image metadata and local path policy.
- `TesseraTests/QuickLookPresenterTests` covers Foundation image parsing, nested content, staging, missing/invalid/oversized images, and private cache paths. It is included in `scripts/integration/run-offline-oracle-tests.sh`.
- `RealHostTransportIntegrationTests/test_liveFileBridgeListsAndRoundTripsFiles` uploads and previews a Markdown/image fixture over real SFTP. Run using `scripts/integration/run-app-transport-tests.sh RUN_DIR TesseraTests/RealHostTransportIntegrationTests/test_liveFileBridgeListsAndRoundTripsFiles`.
- `scripts/integration/visual-cases/f14-markdown-images.sh` captures the host-free iPad/iPhone image fixture for the suite's aggregate visual review.
- `scripts/integration/run-android-markdown-image-tests.sh OUT_DIR [pixel_7|pixel_tablet]` checks real native parsing, staging, activity dispatch, and rendered image pixels on a disposable Android emulator. Set `JAVA_HOME` and `ANDROID_SDK_ROOT`; the runner deletes its AVD on exit.
- Android unit targets: `:files:testDebugUnitTest :markdown:testDebugUnitTest`; lint: `:files:lintDebug`.
