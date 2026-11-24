import type { CapacitorConfig } from '@capacitor/cli';

/**
 * iOS shell around the same web app. `build:ios` writes a service-worker-free
 * bundle to `dist-ios`, and `cap sync` copies it into the Xcode project.
 *
 * Nothing here points at a server. Dose, lab, and supply records stay in
 * WKWebView localStorage on the phone.
 */
const config: CapacitorConfig = {
    appId: 'com.hellolaoyang.hrttracker',
    appName: 'HRT Tracker',
    webDir: 'dist-ios',
    backgroundColor: '#ffffff',
    ios: {
        // The layout already pads for the notch and the home indicator.
        contentInset: 'never',
    },
};

export default config;
