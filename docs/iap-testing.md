# Unlimited Saved Hosts IAP testing

Tessera is free to use and remembers one host. The one-time, non-consumable
**Unlimited Saved Hosts** purchase removes only that saved-host limit.

| Setting | Value |
| --- | --- |
| Bundle ID | `com.bambouville.TesseraApp` |
| Product ID | `com.bambouville.TesseraApp.unlimited_hosts` |
| Product type | Non-Consumable |
| Local test price | US $9.99 |
| Local configuration | `Tessera/StoreKit/Tessera.storekit` |

The price shown in the app always comes from StoreKit. The `$9.99` in the
local configuration is test data; the production price and localized display
price come from App Store Connect.

## What each test environment proves

| Environment | Product source | Charge | Best for |
| --- | --- | --- | --- |
| Xcode StoreKit testing | `Tessera.storekit` | None | Fast UI, purchase, restore, refund, and error testing |
| App Store sandbox | App Store Connect | None | Real product metadata and Apple sandbox services on a physical device |
| TestFlight | App Store Connect, sandbox transactions | None | Release-candidate behavior |
| App Store | App Store Connect production | Real | Final production smoke test only |

Do not describe an Xcode-local test as sandbox or TestFlight evidence. They are
different StoreKit environments.

## Simulator: local StoreKit testing

The shared `Tessera` scheme already has **Run > Options > StoreKit
Configuration** set to `Tessera.storekit`.

Important: launch the app with Xcode's **Run** action for interactive local
StoreKit testing. Building with `xcodebuild`, installing with `simctl`, and then
launching with `simctl` is useful for ordinary UI testing, but does not start
Xcode's local StoreKit test session.

1. Open `Tessera.xcodeproj` and select the `Tessera` scheme.
2. Select the dedicated `Tessera IAP iPhone` or `Tessera IAP iPad` simulator.
3. Confirm **Product > Scheme > Edit Scheme > Run > Options > StoreKit
   Configuration** is `Tessera.storekit`.
4. Run with **Product > Run** (`Command-R`).
5. Save the first host. It must succeed without purchase UI.
6. Try to save a second host. The first over-limit attempt presents the full
   explanation; subsequent attempts use the compact limit notice before the
   user explicitly chooses to view the offer.
7. Confirm the purchase button uses StoreKit's localized `$9.99` test price.
8. Complete the test purchase. The interrupted add/import action should resume
   automatically, and additional hosts should save without prompts.
9. Terminate and run the app again. Unlimited access must return automatically;
   do not tap **restore purchases**.
10. In Xcode, use **Debug > StoreKit > Manage Transactions** to inspect or
    delete the transaction. After deleting/revoking it, foreground or relaunch
    Tessera and confirm existing hosts remain usable while a new over-limit save
    is gated.

Also exercise these paths because they share the persistence gate:

- New Host from the sidebar and `Command-N`.
- A Handoff that needs to create one or more saved hosts.
- Nearby Setup importing zero, one, and multiple new hosts.
- Purchase cancellation, pending approval, failed purchase, and unavailable
  product states.
- iPhone compact layout and iPad landscape layout.

To start the local transaction history over, delete the test transaction in
Xcode's StoreKit transaction manager. To start host data over, use a dedicated
disposable simulator; never erase or uninstall Tessera from a simulator that
contains wanted hosts, keys, or session state.

## Automated local checks

Run the focused policy and StoreKit suite on a disposable simulator:

```sh
xcodebuild test \
  -project Tessera.xcodeproj \
  -scheme Tessera \
  -destination 'platform=iOS Simulator,name=Tessera IAP iPhone' \
  -only-testing:TesseraTests/SavedHostAdmissionPolicyTests \
  -only-testing:TesseraTests/HostAccessStoreTests \
  -only-testing:TesseraTests/StoreKitPurchaseTests
```

Before release, run the repository's comprehensive regression gate as well:

```sh
./scripts/integration/run-integration-tests.sh
```

## Physical device: immediate Xcode-local unlock

This is the quickest no-charge physical-device test and does not require the
product to exist in App Store Connect.

1. Enable Developer Mode on the iPhone or iPad and pair it with Xcode.
2. Keep `Tessera.storekit` selected under the scheme's Run options.
3. Select the physical device and run Tessera from Xcode.
4. Save one host, then attempt a second and complete the local purchase sheet.
5. Relaunch from Xcode and confirm the unlock restores automatically without a
   **restore purchases** tap.

The unlock belongs to this local StoreKit test environment. It is not a real
purchase and does not transfer to TestFlight or App Store builds.

## Physical device: App Store sandbox

Use this lane to test the real App Store Connect product without a charge.

### App Store Connect setup

1. Accept the current Paid Apps Agreement in App Store Connect.
2. Open Tessera, then **Monetization > In-App Purchases**, and create a
   **Non-Consumable** product.
3. Use the exact product ID
   `com.bambouville.TesseraApp.unlimited_hosts`; product IDs cannot be edited
   after creation.
4. Add the customer-facing name and description, choose the intended base
   price, configure country/region availability, and complete required review
   metadata.
5. Under **Users and Access > Sandbox**, create a Sandbox Apple Account that
   has never been used as a normal Apple Account.
6. Allow up to one hour for new or changed product metadata to reach sandbox.

### Run the sandbox test

1. In **Product > Scheme > Edit Scheme > Run > Options**, set **StoreKit
   Configuration** to **None**. Otherwise the local file masks App Store
   Connect and this is not a sandbox test.
2. Run the development-signed app from Xcode on a Developer Mode device.
3. Attempt to buy Unlimited Saved Hosts. At the sandbox sign-in prompt, use the
   Sandbox Apple Account. On current iOS/iPadOS, the account is then available
   under **Settings > Developer > Sandbox Apple Account**.
4. Confirm the payment sheet says it is a sandbox environment. Sandbox
   transactions do not charge a payment method.
5. Complete the purchase, relaunch, and verify automatic entitlement recovery
   without tapping **restore purchases**.
6. Test the same Sandbox Apple Account on the other device. After installing
   and launching Tessera there, an over-limit save or Nearby Setup import must
   silently discover the existing purchase and proceed without a Restore tap.
7. Use **Settings > Developer > Sandbox Apple Account > Manage** to clear
   purchase history when a clean repurchase test is needed. Sign out and back
   in afterward if the device still caches the old history.

## Physical device: TestFlight

TestFlight builds automatically use sandbox transactions, so purchases do not
charge testers. The product must exist in App Store Connect and be available to
the build.

1. Upload the release candidate and install it from TestFlight.
2. Buy Unlimited Saved Hosts through the same second-host gate.
3. Relaunch and verify automatic recovery.
4. Install the TestFlight build on the second device using the same purchase
   account and verify the unlock appears automatically there too.
5. For controlled sandbox scenarios, sign in to the Sandbox Apple Account from
   Developer settings as described by Apple. Keep production and sandbox test
   accounts clearly separated.

Because this is Tessera's first non-consumable IAP, submit it for App Review
with the new app version that introduces it.

## Legacy paid-customer test

Only a verified **production** App Transaction whose original purchase date is
strictly before the customer-protective grace cutoff—August 14, 2026 at noon
in New York (`2026-08-14T16:00:00Z`)—receives the legacy-paid entitlement.
v0.3.1 became free on August 12, but its production grandfathering was wrong;
the grace window deliberately includes every download before the hotfix
cutoff. The date is also necessary because paid v0.2.0 and shipped free v0.3.1
both used build 1. Xcode StoreKit, sandbox, and TestFlight app transactions are
deliberately not treated as old paid downloads, so those environments can
exercise the new free-to-IAP path.

For the real migration check, update a physical device whose Apple Account
previously downloaded the paid App Store version using the released production
App Store update. The production build should show **included with your
original Tessera purchase**, allow multiple hosts, and show no promotional
host-page banner or purchase prompt. TestFlight cannot prove this production
App Transaction classification; use the deterministic tests before release.
Do not delete the paid App Store install or its data before recording the
production update-path evidence.

## Release checklist

- App Store Connect product ID exactly matches the code and bundle.
- Production IAP price is the intended price; the app displays StoreKit's
  localized value rather than hard-coded copy.
- App price changes to Free in coordination with this binary and IAP release.
- First non-consumable is included with the new app-version submission.
- Release version is 0.3.3 (build 4); never reset the App Store build number.
- New customer: one host is free; second host is gated.
- IAP customer: purchase, relaunch, reinstall/new device, and automatic restore
  all grant unlimited hosts without extra taps.
- Legacy paid customer: unlimited hosts with no promotion or purchase prompt.
- Refund/revocation: existing hosts remain intact; future over-limit additions
  are gated.
- iPhone and iPad layouts pass, including iPad landscape.

## Apple references

- [Setting up StoreKit Testing in Xcode](https://developer.apple.com/documentation/xcode/setting-up-storekit-testing-in-xcode)
- [Testing In-App Purchases with sandbox](https://developer.apple.com/documentation/storekit/testing-in-app-purchases-with-sandbox)
- [Testing subscriptions and In-App Purchases in TestFlight](https://developer.apple.com/help/app-store-connect/test-a-beta-version/testing-subscriptions-and-in-app-purchases-in-testflight/)
- [Create a non-consumable In-App Purchase](https://developer.apple.com/help/app-store-connect/manage-in-app-purchases/create-consumable-or-non-consumable-in-app-purchases)
- [Submit an In-App Purchase](https://developer.apple.com/help/app-store-connect/manage-submissions-to-app-review/submit-an-in-app-purchase/)
