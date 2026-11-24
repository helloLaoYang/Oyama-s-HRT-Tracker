/**
 * The iOS app is the same web bundle inside WKWebView. Capacitor injects
 * `window.Capacitor` before any page script runs. The website and the Tauri
 * shell do not, so this stays false there and the web bundle does not have to
 * import Capacitor up front.
 */
export interface NativeShellGlobal {
    Capacitor?: {
        isNativePlatform?: () => boolean;
    };
}

export function isNativeAppShell(target: object | null | undefined): boolean {
    try {
        // `Window` does not declare the bridge, and a type with only optional
        // fields is too weak for TypeScript to accept `window` directly.
        return (target as NativeShellGlobal | null | undefined)?.Capacitor?.isNativePlatform?.() === true;
    } catch {
        return false;
    }
}

/**
 * Match the iOS status-bar text to the page. Light text on a dark page, dark
 * text on a light page. The webview draws under the status bar so the existing
 * safe-area padding still applies. No-op in a browser.
 */
export function syncNativeStatusBar(isDark: boolean): void {
    if (typeof window === 'undefined' || !isNativeAppShell(window)) return;
    void import('@capacitor/status-bar')
        .then(({ StatusBar, Style }) =>
            StatusBar.setOverlaysWebView({ overlay: true }).then(() =>
                StatusBar.setStyle({ style: isDark ? Style.Dark : Style.Light }),
            ),
        )
        .catch(() => {
            // A shell without the plugin, or a failed bridge call. The page
            // itself is already themed.
        });
}
