import { defineConfig } from 'vite';
import react from '@vitejs/plugin-react';
import { VitePWA } from 'vite-plugin-pwa';
import { resolveApiOrigin } from './e2e/apiOrigin';

export default defineConfig(() => {
    // iOS shell (`npm run build:ios`). The phone loads these files from the
    // app bundle. The service worker is left out: WKWebView would otherwise
    // let a precache intercept the bundled pages.
    const nativeShell = process.env.CAPACITOR_BUILD === '1';
    const pwa = VitePWA({
        // A new build waits until the user taps refresh in the update
        // prompt (src/utils/swUpdate.ts registers the worker itself).
        registerType: 'prompt',
        injectRegister: false,
        includeAssets: ['favicon.png', 'apple-touch-icon.png', 'pwa-192x192.png', 'pwa-512x512.png'],
        manifest: {
            name: 'HRT Tracker',
            short_name: 'HRT Tracker',
            description: 'Log HRT doses and estimate hormone levels',
            theme_color: '#FFFFFF',
            background_color: '#FFFFFF',
            display: 'standalone',
            orientation: 'portrait',
            icons: [
                {
                    src: 'pwa-192x192.png',
                    sizes: '192x192',
                    type: 'image/png',
                    purpose: 'any maskable',
                },
                {
                    src: 'pwa-512x512.png',
                    sizes: '512x512',
                    type: 'image/png',
                    purpose: 'any maskable',
                },
            ],
        },
        workbox: {
            // Shared pages require the network API and should always load the
            // current application shell instead of an older precached shell.
            navigateFallbackDenylist: [/^\/share(?:\/|$)/],
        },
    });
    return {
        build: nativeShell ? { outDir: 'dist-ios', emptyOutDir: true } : undefined,
        server: {
            port: 3000,
            host: '0.0.0.0',
            proxy: {
                '/api': {
                    target: resolveApiOrigin(),
                    changeOrigin: true,
                    secure: false,
                },
            },
        },
        plugins: [react(), ...(nativeShell ? [] : [pwa])],
    };
});
