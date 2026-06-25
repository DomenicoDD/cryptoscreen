# StoreKit setup

cryptoscreen uses one auto-renewable subscription for sender-side encrypted image attachments:

- Product ID: `com.domenico.privacyscreen.pro.images.monthly`
- Reference name: `Pro Images Monthly`
- Display name: `cryptoscreen Pro Images`
- Subscription group: `cryptoscreen Pro`
- Duration: `1 month`
- Price: `2.99` per month in App Store Connect for the primary storefront

The app-side StoreKit implementation loads this product ID and displays Apple's localized price from `Product.displayPrice`. Do not hardcode the live currency string in Swift.

For local testing in Xcode, use `Products.storekit`:

1. Open the `PrivacyScreen` scheme.
2. Choose `Run > Options`.
3. Set `StoreKit Configuration` to `Products.storekit`.
4. Run the app and open the image attachment paywall.

The matching auto-renewable subscription has been created in App Store Connect:

- App Store Connect subscription ID: `6784159341`
- Subscription group ID: `22186947`
- Current App Store Connect state: `READY_TO_SUBMIT`

Attach the subscription to the app version when submitting the build that contains the image-attachment paywall. The local `.storekit` file is only for simulator/local StoreKit testing.
